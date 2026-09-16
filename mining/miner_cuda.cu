/**
 * Standalone GPU (CUDA) miner for Elektron Net.
 *
 * Protocol layer is a 1:1 port of mining/miner.cpp (solo via getblocktemplate
 * + submitblock, pool via Stratum V1) -- read that file and
 * doc-elektron/mining-pool-integration.md for the protocol background. The
 * only change is where the hashing happens: instead of CPU threads iterating
 * nonces, a CUDA kernel scans the nonce space on the GPU.
 *
 * Why the kernel is simple (midstate optimisation):
 *
 * The Elektron consensus rules pin the coinbase scriptSig to
 * coinbase_script_sig_prefix (see mining-pool-integration.md section 3.2),
 * so -- exactly like miner.cpp and the reference pool -- the only header
 * entropy this miner iterates is nNonce. Bytes 0..63 of the 80-byte header
 * (version | prevhash | merkle[0..27]) do not change while a job is being
 * scanned, so SHA-256 over the first 64-byte block is computed once per job
 * on the host (the "midstate") and uploaded to the device. Each nonce
 * attempt is then exactly two compression-function evaluations:
 *
 *   1. compress(midstate, block2)   block2 = header[64..79] | padding | 640
 *   2. compress(H0, digest|padding|256)   -> the final sha256d digest
 *
 * CPU + GPU (solo mode): mining.threads (or cpu.threads) host threads mine
 * alongside the GPU. The nonce space is partitioned disjointly: the GPU
 * sweeps chunks [0, gpu_chunks), each CPU thread owns one chunk above that
 * range. CPU threads hash with the same midstate trick (SHA256_Transform,
 * which OpenSSL dispatches to the SHA-NI/AVX2 assembly) and roll their own
 * nTime once their chunk is exhausted.
 *
 * nTime rolling (solo mode): a full sweep covers the whole 2^32 nonce space
 * in ~2.6 s, while templates stay valid for ~60 s. Re-scanning the identical
 * header would waste ~96% of the hashes, so when a refetched template is
 * byte-identical to the current job (nTime excepted) the miner rolls nTime
 * forward instead. Only header bytes 68..71 change -- the midstate is
 * unaffected. Rolling is bounded by GBT's "maxtime" (consensus allows at
 * most now + 2h).
 *
 * Everything else (JSON parsing without external deps, coinbase layout,
 * merkle construction, Stratum wire format, share/difficulty maths) is kept
 * byte-for-byte compatible with miner.cpp so blocks and shares are accepted
 * by the node and the reference pool.
 *
 * Build (see mining/README.md, "GPU miner"):
 *   cmake -B build-cuda -DELEKTRON_BUILD_CUDA_MINER=ON   (auto-detected)
 *   cmake --build build-cuda --target elektron_miner_cuda
 * or directly:
 *   nvcc -O3 -std=c++17 -arch=sm_75 miner_cuda.cu -o elektron_miner_cuda \
 *       -lcurl -lssl -lcrypto -lpthread
 *
 * Usage:
 *   ./elektron_miner_cuda config.json            # solo or pool, from config
 *   ./elektron_miner_cuda --selftest [config]    # kernel correctness + bench
 *
 * Selftest (also runs on every startup unless --noselftest is given):
 *   1. GPU sha256d digests are compared against OpenSSL for 4096 random
 *      80-byte headers.
 *   2. A known-nonce scan: the target is set to the digest of a chosen
 *      nonce; the kernel must find a qualifying nonce and the report is
 *      re-verified on the CPU.
 *   3. difficulty -> target conversion sanity (diff 1 -> 2^224).
 *   4. GPU throughput benchmark.
 *   5. CPU midstate path (SHA256_Transform) vs plain sha256d.
 *   6. CPU single-thread throughput benchmark.
 *   7. CPU worker pool: a CpuPool scan finds a qualifying nonce, re-verifies
 *      it independently and hands it to the poll_find() consumer.
 *
 * Elektron Net v4.0:
 * UTXO attestation via coinbase_required_outputs, 60 s block spacing,
 * Stratum V1 with extranonce2_size = 0 (coinb1 is the complete coinbase,
 * nothing is spliced -- see miner.cpp's pool section for the wire format
 * references against elektron-net-pool).
 */

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <cuda_runtime.h>

#include <curl/curl.h>
#include <openssl/sha.h>

#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

// ---------------------------------------------------------------------------
// Host-side SHA-256d helpers (OpenSSL)
// ---------------------------------------------------------------------------

static void sha256d(const uint8_t *data, size_t len, uint8_t out[32]) {
    uint8_t hash1[32];
    SHA256(data, len, hash1);
    SHA256(hash1, 32, out);
}

// Midstate: SHA-256 state (ctx.h, big-endian-decoded words) after the first
// 64 bytes of the header. The device continues from these words.
static void sha256_midstate(const uint8_t *header, uint32_t midstate[8]) {
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    SHA256_Transform(&ctx, header); // process exactly one 64-byte block
    for (int i = 0; i < 8; ++i) midstate[i] = ctx.h[i];
}

// CPU worker path: sha256d(header80) continuing from a precomputed midstate
// (header[0..63] compressed once per job). Two SHA256_Transform calls per
// nonce; OpenSSL dispatches to the SHA-NI/AVX2 assembly on x86, so this is
// the fastest portable per-core path. Digest bytes are written MSB-first
// (out[0] = most significant byte), same layout as sha256d().
static void sha256d_midstate(const uint32_t midstate[8], const uint8_t header80[80],
                             uint8_t out[32]) {
    SHA256_CTX ctx;
    SHA256_Init(&ctx);
    std::memcpy(ctx.h, midstate, 8 * sizeof(uint32_t));

    // Block 2: header[64..79] | 0x80 | zeros | 640 bits, big-endian length.
    uint8_t block2[64];
    std::memcpy(block2, header80 + 64, 16); // merkle tail | nTime | nBits | nonce
    block2[16] = 0x80;
    std::memset(block2 + 17, 0, 45);
    block2[62] = 0x02;
    block2[63] = 0x80;
    SHA256_Transform(&ctx, block2);

    // Block 3: inner digest (big-endian bytes of ctx.h) | 0x80 | zeros | 256.
    uint8_t block3[64];
    for (int i = 0; i < 8; ++i) {
        block3[4 * i + 0] = static_cast<uint8_t>(ctx.h[i] >> 24);
        block3[4 * i + 1] = static_cast<uint8_t>(ctx.h[i] >> 16);
        block3[4 * i + 2] = static_cast<uint8_t>(ctx.h[i] >> 8);
        block3[4 * i + 3] = static_cast<uint8_t>(ctx.h[i]);
    }
    block3[32] = 0x80;
    std::memset(block3 + 33, 0, 29);
    block3[62] = 0x01;
    block3[63] = 0x00;
    SHA256_Init(&ctx);
    SHA256_Transform(&ctx, block3);

    for (int i = 0; i < 8; ++i) {
        out[4 * i + 0] = static_cast<uint8_t>(ctx.h[i] >> 24);
        out[4 * i + 1] = static_cast<uint8_t>(ctx.h[i] >> 16);
        out[4 * i + 2] = static_cast<uint8_t>(ctx.h[i] >> 8);
        out[4 * i + 3] = static_cast<uint8_t>(ctx.h[i]);
    }
}

static bool hash_le_target(const uint8_t hash[32], const uint8_t target_msb[32]) {
    // SHA256d hash is compared as a little-endian integer; GBT "target" hex is MSB-first.
    for (int i = 0; i < 32; ++i) {
        const uint8_t h = hash[31 - i];
        const uint8_t t = target_msb[i];
        if (h < t) return true;
        if (h > t) return false;
    }
    return true;
}

static std::string hex_encode(const uint8_t *data, size_t len) {
    std::ostringstream oss;
    oss << std::hex << std::setfill('0');
    for (size_t i = 0; i < len; ++i)
        oss << std::setw(2) << static_cast<int>(data[i]);
    return oss.str();
}

static std::vector<uint8_t> hex_decode(const std::string &hex) {
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

// ---------------------------------------------------------------------------
// JSON helpers (minimal, no external dependency) -- ported from miner.cpp
// ---------------------------------------------------------------------------

static std::string json_quote_string(const std::string &value) {
    std::ostringstream oss;
    oss << '"';
    for (char ch : value) {
        switch (ch) {
        case '\\': oss << "\\\\"; break;
        case '"': oss << "\\\""; break;
        default: oss << ch; break;
        }
    }
    oss << '"';
    return oss.str();
}

static std::string json_rpc(const std::string &method,
                            const std::vector<std::string> &params) {
    std::ostringstream oss;
    oss << "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"" << method << "\",\"params\":[";
    for (size_t i = 0; i < params.size(); ++i) {
        if (i) oss << ",";
        oss << params[i];
    }
    oss << "]}";
    return oss.str();
}

static std::string extract_json_string(const std::string &json, const std::string &key) {
    const std::string quoted = "\"" + key + "\"";
    size_t pos = json.find(quoted);
    if (pos == std::string::npos) return "";
    pos = json.find('"', pos + quoted.size());
    if (pos == std::string::npos) return "";
    size_t end = json.find('"', pos + 1);
    if (end == std::string::npos) return "";
    return json.substr(pos + 1, end - pos - 1);
}

static int64_t extract_json_int(const std::string &json, const std::string &key) {
    const std::string quoted = "\"" + key + "\"";
    size_t pos = json.find(quoted);
    if (pos == std::string::npos) return 0;
    pos = json.find(':', pos + quoted.size());
    if (pos == std::string::npos) return 0;
    ++pos;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;
    size_t end = pos;
    while (end < json.size() && (json[end] == '-' || (json[end] >= '0' && json[end] <= '9'))) ++end;
    if (end == pos) return 0;
    return std::stoll(json.substr(pos, end - pos));
}

static std::string extract_json_section(const std::string &json, const std::string &key) {
    const std::string quoted = "\"" + key + "\"";
    size_t pos = json.find(quoted);
    if (pos == std::string::npos) return "";
    pos = json.find('{', pos);
    if (pos == std::string::npos) return "";
    int depth = 0;
    for (size_t i = pos; i < json.size(); ++i) {
        if (json[i] == '{') ++depth;
        else if (json[i] == '}') {
            --depth;
            if (depth == 0) return json.substr(pos, i - pos + 1);
        }
    }
    return "";
}

static std::string extract_json_result(const std::string &json) {
    const std::string section = extract_json_section(json, "result");
    return section.empty() ? json : section;
}

// ---------------------------------------------------------------------------
// HTTP / RPC -- ported from miner.cpp
// ---------------------------------------------------------------------------

static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    ((std::string *)userp)->append((char *)contents, size * nmemb);
    return size * nmemb;
}

class RpcClient {
public:
    std::string url;
    std::string user;
    std::string password;

    RpcClient(const std::string &u, const std::string &usr, const std::string &pwd)
        : url(u), user(usr), password(pwd) {}

    std::string call(const std::string &method,
                     const std::vector<std::string> &params = {}) {
        CURL *curl = curl_easy_init();
        if (!curl) throw std::runtime_error("curl init failed");

        const std::string payload = json_rpc(method, params);
        std::string readBuffer;
        struct curl_slist *headers = nullptr;
        headers = curl_slist_append(headers, "Content-Type: application/json");

        const std::string creds = user + ":" + password;
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.c_str());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);
        curl_easy_setopt(curl, CURLOPT_USERPWD, creds.c_str());
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);

        const CURLcode res = curl_easy_perform(curl);
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);

        if (res != CURLE_OK)
            throw std::runtime_error(std::string("curl error: ") + curl_easy_strerror(res));

        return readBuffer;
    }
};

// ---------------------------------------------------------------------------
// Config -- ported from miner.cpp, plus an optional "cuda" section
// ---------------------------------------------------------------------------

struct Config {
    std::string rpc_url = "http://127.0.0.1:8332";
    std::string rpc_user = "user";
    std::string rpc_password = "password";
    std::string mining_address;
    int threads = 4; // unused by the GPU miner, kept for config compatibility
    bool continuous = true;

    // Pool (Stratum V1) mode -- independent of the RPC/mining fields above.
    bool pool_enabled = false;
    std::string pool_url;
    std::string pool_user;
    std::string pool_password = "x";

    // Optional CUDA section.
    int cuda_device = 0;

    // Optional CPU worker pool (solo mode): host threads that mine alongside
    // the GPU. -1 = follow mining.threads for backwards compatibility, 0 =
    // disabled, >0 = CPU thread count.
    int cpu_threads = -1;

    void load(const std::string &path) {
        std::ifstream f(path);
        if (!f.is_open()) {
            std::cerr << "Warning: cannot open " << path << ", using defaults.\n";
            return;
        }
        const std::string json((std::istreambuf_iterator<char>(f)),
                               std::istreambuf_iterator<char>());

        if (const std::string rpc = extract_json_section(json, "rpc"); !rpc.empty()) {
            if (const std::string u = extract_json_string(rpc, "url"); !u.empty()) rpc_url = u;
            if (const std::string u = extract_json_string(rpc, "user"); !u.empty()) rpc_user = u;
            if (const std::string p = extract_json_string(rpc, "password"); !p.empty()) rpc_password = p;
        }
        if (const std::string mining = extract_json_section(json, "mining"); !mining.empty()) {
            if (const std::string a = extract_json_string(mining, "address"); !a.empty()) mining_address = a;
            if (const int64_t t = extract_json_int(mining, "threads"); t > 0) threads = static_cast<int>(t);
            continuous = mining.find("\"continuous\":true") != std::string::npos ||
                         mining.find("\"continuous\": true") != std::string::npos;
        }
        if (const std::string pool = extract_json_section(json, "pool"); !pool.empty()) {
            pool_enabled = pool.find("\"enabled\":true") != std::string::npos ||
                           pool.find("\"enabled\": true") != std::string::npos;
            if (const std::string u = extract_json_string(pool, "url"); !u.empty()) pool_url = u;
            if (const std::string u = extract_json_string(pool, "user"); !u.empty()) pool_user = u;
            if (const std::string p = extract_json_string(pool, "password"); !p.empty()) pool_password = p;
        }
        if (const std::string cuda = extract_json_section(json, "cuda"); !cuda.empty()) {
            if (const int64_t d = extract_json_int(cuda, "device"); d >= 0) cuda_device = static_cast<int>(d);
        }
        if (const std::string cpu = extract_json_section(json, "cpu"); !cpu.empty()) {
            // 0 disables the CPU workers, >0 sets the thread count.
            cpu_threads = static_cast<int>(extract_json_int(cpu, "threads"));
        }

        if (threads <= 0) threads = 4;
    }
};

// ---------------------------------------------------------------------------
// Transaction / block serialization (matches mining/miner.py) -- ported
// verbatim from miner.cpp
// ---------------------------------------------------------------------------

static void append_compact_size(std::vector<uint8_t> &out, uint64_t n) {
    if (n < 0xfd) {
        out.push_back(static_cast<uint8_t>(n));
    } else if (n <= 0xffff) {
        out.push_back(0xfd);
        out.push_back(static_cast<uint8_t>(n & 0xff));
        out.push_back(static_cast<uint8_t>((n >> 8) & 0xff));
    } else if (n <= 0xffffffff) {
        out.push_back(0xfe);
        for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>((n >> (8 * i)) & 0xff));
    } else {
        out.push_back(0xff);
        for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>((n >> (8 * i)) & 0xff));
    }
}

static void append_script_num(std::vector<uint8_t> &out, int64_t n) {
    if (n == -1) {
        out.push_back(0x4f);
        return;
    }
    if (n == 0) {
        out.push_back(0x00);
        return;
    }
    if (n >= 1 && n <= 16) {
        out.push_back(static_cast<uint8_t>(0x50 + n));
        return;
    }
    bool neg = n < 0;
    uint64_t abs = neg ? static_cast<uint64_t>(-(n + 1)) + 1 : static_cast<uint64_t>(n);
    std::vector<uint8_t> result;
    while (abs) {
        result.push_back(static_cast<uint8_t>(abs & 0xff));
        abs >>= 8;
    }
    if (result.back() & 0x80) {
        result.push_back(neg ? 0x80 : 0x00);
    } else if (neg) {
        result.back() |= 0x80;
    }
    out.push_back(static_cast<uint8_t>(result.size()));
    out.insert(out.end(), result.begin(), result.end());
}

static bool is_witness_commitment_script(const std::vector<uint8_t> &script) {
    static const uint8_t kPattern[] = {0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed};
    return script.size() >= sizeof(kPattern) &&
           std::memcmp(script.data(), kPattern, sizeof(kPattern)) == 0;
}

struct TxOutTemplate {
    int64_t value{0};
    std::vector<uint8_t> script;
};

struct GbtTransaction {
    std::string txid;
    std::string data_hex;
};

struct BlockTemplate {
    int version{1};
    int height{0};
    int64_t coinbasevalue{0};
    std::string prev_blockhash;
    uint32_t curtime{0};
    uint32_t bits{0};
    std::string target_hex;
    std::string script_sig_prefix_hex;
    std::vector<TxOutTemplate> required_outputs;
    std::string default_witness_commitment;
    std::vector<GbtTransaction> transactions;
};

static std::vector<TxOutTemplate> parse_required_outputs(const std::string &json) {
    std::vector<TxOutTemplate> outs;
    size_t pos = json.find("\"coinbase_required_outputs\"");
    if (pos == std::string::npos) return outs;
    pos = json.find('[', pos);
    if (pos == std::string::npos) return outs;

    size_t i = pos + 1;
    while (i < json.size()) {
        size_t obj_start = json.find('{', i);
        if (obj_start == std::string::npos || obj_start > json.find(']', pos)) break;
        size_t obj_end = json.find('}', obj_start);
        if (obj_end == std::string::npos) break;
        const std::string obj = json.substr(obj_start, obj_end - obj_start + 1);
        TxOutTemplate out;
        out.value = extract_json_int(obj, "value");
        const std::string spk = extract_json_string(obj, "scriptPubKey");
        if (!spk.empty()) out.script = hex_decode(spk);
        if (!out.script.empty()) outs.push_back(std::move(out));
        i = obj_end + 1;
    }
    return outs;
}

static std::vector<GbtTransaction> parse_transactions(const std::string &json) {
    std::vector<GbtTransaction> txs;
    size_t pos = json.find("\"transactions\"");
    if (pos == std::string::npos) return txs;
    pos = json.find('[', pos);
    if (pos == std::string::npos) return txs;

    size_t i = pos + 1;
    while (i < json.size()) {
        size_t obj_start = json.find('{', i);
        if (obj_start == std::string::npos || obj_start > json.find(']', pos)) break;
        size_t obj_end = json.find('}', obj_start);
        if (obj_end == std::string::npos) break;
        const std::string obj = json.substr(obj_start, obj_end - obj_start + 1);
        GbtTransaction tx;
        tx.txid = extract_json_string(obj, "txid");
        tx.data_hex = extract_json_string(obj, "data");
        if (!tx.data_hex.empty()) txs.push_back(std::move(tx));
        i = obj_end + 1;
    }
    return txs;
}

static BlockTemplate parse_template(const std::string &json) {
    const std::string body = extract_json_result(json);
    BlockTemplate tmpl;
    tmpl.version = static_cast<int>(extract_json_int(body, "version"));
    tmpl.height = static_cast<int>(extract_json_int(body, "height"));
    tmpl.coinbasevalue = extract_json_int(body, "coinbasevalue");
    tmpl.prev_blockhash = extract_json_string(body, "previousblockhash");
    tmpl.curtime = static_cast<uint32_t>(extract_json_int(body, "curtime"));
    const std::string bits_str = extract_json_string(body, "bits");
    if (!bits_str.empty()) tmpl.bits = static_cast<uint32_t>(std::stoul(bits_str, nullptr, 16));
    tmpl.target_hex = extract_json_string(body, "target");
    tmpl.script_sig_prefix_hex = extract_json_string(body, "coinbase_script_sig_prefix");
    tmpl.required_outputs = parse_required_outputs(body);
    tmpl.default_witness_commitment = extract_json_string(body, "default_witness_commitment");
    tmpl.transactions = parse_transactions(body);
    return tmpl;
}

static std::vector<uint8_t> address_to_scriptpubkey(RpcClient &rpc, const std::string &address) {
    const std::string resp = rpc.call("validateaddress", {json_quote_string(address)});
    if (resp.find("\"isvalid\":true") == std::string::npos &&
        resp.find("\"isvalid\": true") == std::string::npos) {
        throw std::runtime_error("Invalid payout address: " + address);
    }
    const std::string spk_hex = extract_json_string(resp, "scriptPubKey");
    if (spk_hex.empty()) throw std::runtime_error("validateaddress returned no scriptPubKey");
    return hex_decode(spk_hex);
}

static void build_coinbase_tx(const BlockTemplate &tmpl,
                              const std::vector<uint8_t> &script_pubkey,
                              std::vector<uint8_t> &tx_out,
                              std::vector<uint8_t> &tx_no_witness_out) {
    std::vector<uint8_t> script_sig;
    if (!tmpl.script_sig_prefix_hex.empty()) {
        script_sig = hex_decode(tmpl.script_sig_prefix_hex);
    } else {
        append_script_num(script_sig, tmpl.height);
        if (script_sig.size() < 2) script_sig.push_back(0x00); // OP_0 — bad-cb-length guard
    }

    std::vector<uint8_t> outputs;
    auto append_u64_le = [](std::vector<uint8_t> &buf, uint64_t v) {
        for (int i = 0; i < 8; ++i) buf.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
    };
    append_u64_le(outputs, static_cast<uint64_t>(tmpl.coinbasevalue));
    append_compact_size(outputs, script_pubkey.size());
    outputs.insert(outputs.end(), script_pubkey.begin(), script_pubkey.end());

    size_t output_count = 1;
    bool has_witness = !tmpl.default_witness_commitment.empty();

    if (!tmpl.required_outputs.empty()) {
        for (const auto &req : tmpl.required_outputs) {
            append_u64_le(outputs, static_cast<uint64_t>(req.value));
            append_compact_size(outputs, req.script.size());
            outputs.insert(outputs.end(), req.script.begin(), req.script.end());
            ++output_count;
            if (is_witness_commitment_script(req.script)) has_witness = true;
        }
    } else if (!tmpl.default_witness_commitment.empty()) {
        const auto wc = hex_decode(tmpl.default_witness_commitment);
        append_u64_le(outputs, 0);
        append_compact_size(outputs, wc.size());
        outputs.insert(outputs.end(), wc.begin(), wc.end());
        output_count = 2;
        has_witness = true;
    }

    auto assemble = [&](bool with_witness) {
        std::vector<uint8_t> tx;
        auto append_i32_le = [](std::vector<uint8_t> &buf, int32_t v) {
            for (int i = 0; i < 4; ++i) buf.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
        };
        append_i32_le(tx, 2); // version
        if (with_witness) {
            tx.push_back(0x00);
            tx.push_back(0x01);
        }
        append_compact_size(tx, 1); // 1 input
        tx.insert(tx.end(), 32, 0x00); // null prevout hash
        append_i32_le(tx, 0xffffffff); // prevout index
        append_compact_size(tx, script_sig.size());
        tx.insert(tx.end(), script_sig.begin(), script_sig.end());
        append_i32_le(tx, 0xfffffffe); // nSequence
        append_compact_size(tx, output_count);
        tx.insert(tx.end(), outputs.begin(), outputs.end());
        if (with_witness) {
            append_compact_size(tx, 1); // 1 witness stack item
            append_compact_size(tx, 32);
            tx.insert(tx.end(), 32, 0x00);
        }
        append_i32_le(tx, tmpl.height > 0 ? tmpl.height - 1 : 0); // nLockTime
        return tx;
    };

    tx_out = assemble(has_witness);
    tx_no_witness_out = assemble(false);
}

static std::vector<uint8_t> compute_merkle_root(std::vector<std::vector<uint8_t>> hashes) {
    if (hashes.empty()) return std::vector<uint8_t>(32, 0);
    while (hashes.size() > 1) {
        if (hashes.size() % 2 == 1) hashes.push_back(hashes.back());
        std::vector<std::vector<uint8_t>> next;
        for (size_t i = 0; i < hashes.size(); i += 2) {
            std::vector<uint8_t> combined;
            combined.insert(combined.end(), hashes[i].begin(), hashes[i].end());
            combined.insert(combined.end(), hashes[i + 1].begin(), hashes[i + 1].end());
            std::vector<uint8_t> h(32);
            sha256d(combined.data(), combined.size(), h.data());
            next.push_back(std::move(h));
        }
        hashes = std::move(next);
    }
    return hashes[0];
}

static std::vector<uint8_t> build_header_bytes(const BlockTemplate &tmpl,
                                               uint32_t nonce,
                                               const uint8_t merkle_root[32]) {
    std::vector<uint8_t> header(80);
    header[0] = tmpl.version & 0xff;
    header[1] = (tmpl.version >> 8) & 0xff;
    header[2] = (tmpl.version >> 16) & 0xff;
    header[3] = (tmpl.version >> 24) & 0xff;

    auto prev = hex_decode(tmpl.prev_blockhash);
    std::reverse(prev.begin(), prev.end());
    std::copy(prev.begin(), prev.end(), header.begin() + 4);

    std::copy(merkle_root, merkle_root + 32, header.begin() + 36);

    header[68] = tmpl.curtime & 0xff;
    header[69] = (tmpl.curtime >> 8) & 0xff;
    header[70] = (tmpl.curtime >> 16) & 0xff;
    header[71] = (tmpl.curtime >> 24) & 0xff;

    header[72] = tmpl.bits & 0xff;
    header[73] = (tmpl.bits >> 8) & 0xff;
    header[74] = (tmpl.bits >> 16) & 0xff;
    header[75] = (tmpl.bits >> 24) & 0xff;

    header[76] = nonce & 0xff;
    header[77] = (nonce >> 8) & 0xff;
    header[78] = (nonce >> 16) & 0xff;
    header[79] = (nonce >> 24) & 0xff;
    return header;
}

// Serializes the full block from a caller-built 80-byte header. The header is
// passed in (not rebuilt from the template) so nTime rolled during mining is
// preserved -- build_header_bytes would stamp the template's original curtime.
static std::string assemble_block_hex(const BlockTemplate &tmpl,
                                      const uint8_t header80[80],
                                      const std::vector<uint8_t> &coinbase_tx) {
    std::string block = hex_encode(header80, 80);

    const size_t tx_count = 1 + tmpl.transactions.size();
    if (tx_count < 0xfd) {
        block += hex_encode(reinterpret_cast<const uint8_t *>(&tx_count), 1);
    } else {
        uint8_t vi[3] = {0xfd, static_cast<uint8_t>(tx_count), static_cast<uint8_t>(tx_count >> 8)};
        block += hex_encode(vi, 3);
    }

    block += hex_encode(coinbase_tx.data(), coinbase_tx.size());
    for (const auto &tx : tmpl.transactions) block += tx.data_hex;
    return block;
}

static void hex_target_to_bytes(const std::string &hex, uint8_t target[32]) {
    std::memset(target, 0, 32);
    const size_t nbytes = hex.size() / 2 < 32 ? hex.size() / 2 : 32;
    for (size_t i = 0; i < nbytes; ++i) {
        target[i] = static_cast<uint8_t>(std::stoul(hex.substr(i * 2, 2), nullptr, 16));
    }
}

static void bits_to_target(uint32_t n_bits, uint8_t target[32]) {
    // Same algorithm as mining/miner.py (handles Stoic Awakening / powLimit compact values).
    const uint32_t exponent = (n_bits >> 24) & 0xff;
    uint64_t coefficient = n_bits & 0x007fffff;
    std::memset(target, 0, 32);
    if (exponent <= 3) {
        coefficient >>= (8 * (3 - exponent));
    } else if (exponent <= 34) {
        const int shift_bytes = static_cast<int>(exponent - 3);
        target[shift_bytes] = static_cast<uint8_t>(coefficient & 0xff);
        if (shift_bytes >= 1) target[shift_bytes - 1] = static_cast<uint8_t>((coefficient >> 8) & 0xff);
        if (shift_bytes >= 2) target[shift_bytes - 2] = static_cast<uint8_t>((coefficient >> 16) & 0xff);
        return;
    } else {
        return;
    }
    target[0] = static_cast<uint8_t>(coefficient & 0xff);
    if (coefficient > 0xff) target[1] = static_cast<uint8_t>((coefficient >> 8) & 0xff);
    if (coefficient > 0xffff) target[2] = static_cast<uint8_t>((coefficient >> 16) & 0xff);
}

// ---------------------------------------------------------------------------
// CUDA kernel
//
// SHA-256 FIPS 180-4, operating on big-endian 32-bit words. Two compression
// calls per nonce attempt (midstate from host -- see file comment).
// ---------------------------------------------------------------------------

__constant__ uint32_t c_K[64];
__constant__ uint32_t c_midstate[8];
__constant__ uint32_t c_target[8];    // MSB-first target as 8 big-endian words
__constant__ uint32_t c_b2w[3];       // header words 64..75 (merkle tail | ntime | nbits)

#define ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

__device__ __forceinline__ uint32_t bs0(uint32_t x) { return ROR32(x, 7) ^ ROR32(x, 18) ^ (x >> 3); }
__device__ __forceinline__ uint32_t bs1(uint32_t x) { return ROR32(x, 17) ^ ROR32(x, 19) ^ (x >> 10); }
__device__ __forceinline__ uint32_t ss0(uint32_t x) { return ROR32(x, 2) ^ ROR32(x, 13) ^ ROR32(x, 22); }
__device__ __forceinline__ uint32_t ss1(uint32_t x) { return ROR32(x, 6) ^ ROR32(x, 11) ^ ROR32(x, 25); }

__device__ __forceinline__ uint32_t ch(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (~x & z); }
__device__ __forceinline__ uint32_t maj(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (x & z) ^ (y & z); }

// One SHA-256 compression of `w[16]` into state `s` (in place). `s` is the
// running state (midstate or IV), NOT the final digest -- the digest of a
// message is the state after the last compress() call. The message schedule
// uses a rolling 16-word buffer; expansion of W[i] and round i MUST run
// interleaved (slot i & 15 holds W[i] only in the iteration that computes
// it -- later expansions overwrite it).
__device__ __forceinline__ void sha256_compress(uint32_t s[8], uint32_t w[16]) {
    uint32_t a = s[0], b = s[1], c = s[2], d = s[3];
    uint32_t e = s[4], f = s[5], g = s[6], h = s[7];
#pragma unroll
    for (int i = 0; i < 64; ++i) {
        if (i >= 16)
            w[i & 15] += bs1(w[(i + 14) & 15]) + w[(i + 9) & 15] + bs0(w[(i + 1) & 15]);
        const uint32_t t1 = h + ss1(e) + ch(e, f, g) + c_K[i] + w[i & 15];
        const uint32_t t2 = ss0(a) + maj(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    s[0] += a; s[1] += b; s[2] += c; s[3] += d;
    s[4] += e; s[5] += f; s[6] += g; s[7] += h;
}

// Mapped (zero-copy) result block shared with the host:
//   [0] found flag  (0 = nothing, 1 = found, 2 = host-requested abort)
//   [1] nonce that produced the hit
//   [2] iteration-count low word  (hashrate accounting, atomicAdd)
//   [3] iteration-count high word
__device__ __forceinline__ bool target_beaten(const uint32_t f[8]) {
    // The digest is compared as a little-endian integer (miner.cpp's
    // hash_le_target / the pool's le256todouble): digest byte 31 is the most
    // significant byte, i.e. the comparison walks digest bytes in REVERSE
    // order against the MSB-first target bytes. Reversed digest bytes pack
    // into words as bswap32(f[7-i]); c_target holds the MSB-first target
    // bytes packed the same way (see GpuResult::set_job). Accept digest <=
    // target (equal counts, matching hash_le_target).
#pragma unroll
    for (int i = 0; i < 8; ++i) {
        const uint32_t r = __byte_perm(f[7 - i], 0, 0x0123); // bswap32
        if (r < c_target[i]) return true;
        if (r > c_target[i]) return false;
    }
    return true;
}

// Scans [base_nonce, base_nonce + nonce_span) grid-stride. Checks the host
// control word every 32 iterations so a new job aborts the current launch
// within microseconds.
__global__ void sha256d_scan_kernel(uint32_t base_nonce, uint32_t nonce_span,
                                    uint32_t *__restrict__ ctrl) {
    const uint32_t total = gridDim.x * blockDim.x;
    const uint32_t gid = blockIdx.x * blockDim.x + threadIdx.x;

    uint32_t iterations = 0;
    for (uint32_t n = base_nonce + gid; n - base_nonce < nonce_span; n += total) {
        if ((iterations & 31) == 0 && ctrl[0] != 0) break;

        uint32_t s[8];
#pragma unroll
        for (int i = 0; i < 8; ++i) s[i] = c_midstate[i];

        uint32_t w[16];
        w[0] = c_b2w[0];               // header[64..67]  (merkle tail)
        w[1] = c_b2w[1];               // header[68..71]  (nTime)
        w[2] = c_b2w[2];               // header[72..75]  (nBits)
        w[3] = __byte_perm(n, 0, 0x0123); // nNonce, little-endian -> BE word (bswap32)
        w[4] = 0x80000000;
        w[5] = w[6] = w[7] = w[8] = w[9] = w[10] = w[11] = w[12] = w[13] = w[14] = 0;
        w[15] = 640;                   // 80 bytes * 8 bits
        sha256_compress(s, w);

        // Second hash over the 32-byte digest: words are the digest itself.
        uint32_t d[16];
#pragma unroll
        for (int i = 0; i < 8; ++i) d[i] = s[i];
        d[8] = 0x80000000;
        d[9] = d[10] = d[11] = d[12] = d[13] = d[14] = 0;
        d[15] = 256;                   // 32 bytes * 8 bits
        uint32_t f[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                         0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
        sha256_compress(f, d);

        ++iterations;

        if (target_beaten(f)) {
            // First writer wins; the host re-verifies the digest before use.
            if (atomicCAS(&ctrl[0], 0, 1) == 0) ctrl[1] = n;
        }
    }

    // 64-bit accounting: carry the 32-bit low word's wrap into the high word.
    const uint32_t before = atomicAdd(&ctrl[2], iterations);
    if (before + iterations < before) atomicAdd(&ctrl[3], 1);
}

// Selftest kernel: full (no midstate) sha256d of one 80-byte header per
// thread, digest written big-endian-word order (identical layout to the
// digest bytes: out[0] is the top byte).
__global__ void sha256d_reference_kernel(const uint32_t *__restrict__ headers_be_words,
                                         uint32_t *__restrict__ out_be_words,
                                         int count) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= count) return;

    const uint32_t *h = headers_be_words + static_cast<size_t>(idx) * 20; // 80 bytes = 20 words

    uint32_t s[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    uint32_t w[16];
#pragma unroll
    for (int i = 0; i < 16; ++i) w[i] = h[i];
    sha256_compress(s, w);

    // Second block of the FIRST hash: header[64..79] | padding | 640.
    uint32_t d[16];
    d[0] = h[16]; d[1] = h[17]; d[2] = h[18]; d[3] = h[19];
    d[4] = 0x80000000;
    d[5] = d[6] = d[7] = d[8] = d[9] = d[10] = d[11] = d[12] = d[13] = d[14] = 0;
    d[15] = 640;
    sha256_compress(s, d);

    // Second hash over the 32-byte digest: words are the digest itself.
    uint32_t d2[16];
#pragma unroll
    for (int i = 0; i < 8; ++i) d2[i] = s[i];
    d2[8] = 0x80000000;
    d2[9] = d2[10] = d2[11] = d2[12] = d2[13] = d2[14] = 0;
    d2[15] = 256;
    uint32_t f[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    sha256_compress(f, d2);

    uint32_t *o = out_be_words + static_cast<size_t>(idx) * 8;
#pragma unroll
    for (int i = 0; i < 8; ++i) o[i] = f[i];
}

// ---------------------------------------------------------------------------
// CUDA host side
// ---------------------------------------------------------------------------

#define CUDA_CHECK(expr)                                                        \
    do {                                                                        \
        const cudaError_t _err = (expr);                                        \
        if (_err != cudaSuccess)                                                \
            throw std::runtime_error(std::string("CUDA error: ") +              \
                                     cudaGetErrorString(_err) + " @ " #expr);   \
    } while (0)

// TRUE_DIFF_ONE from elektron-net-pool's difficulty.utils.ts: the raw sha256d
// digest read as a little-endian integer for a difficulty-1 share. The pool
// computes difficulty = TRUE_DIFF_ONE / le_int(hash), so a difficulty-D share
// is a digest whose little-endian integer value <= 2^224 / D. This converts
// D into that threshold, packed MSB-first into target_msb[32] (same layout
// GBT's "target" hex uses).
static void difficulty_to_target_be(double diff, uint8_t target_msb[32]) {
    std::memset(target_msb, 0, 32);
    if (!(diff > 0.0) || !std::isfinite(diff)) return; // -> all-zero target (accept everything)

    // diff = M * 2^exp2 with M a 53-bit integer (frexp + mantissa rounding).
    int exp2 = 0;
    const double frac = std::frexp(diff, &exp2);          // diff = frac * 2^exp2
    uint64_t mant = static_cast<uint64_t>(std::ldexp(frac, 53)); // 2^52 <= mant < 2^53

    // target = 2^224 / diff = 2^(224 - exp2 + 53) / mant = 2^N / mant.
    // Numerator as 10x32-bit limbs (enough for N up to 320); quotient by a
    // 53-bit integer via schoolbook bit-by-bit division.
    // If the target would overflow 256 bits, clamp to "accept everything".
    const long long N = 224LL - exp2 + 53;
    uint32_t num[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    if (N >= 0 && N < 320) {
        num[N / 32] = static_cast<uint32_t>(1u << (N % 32));
    }
    long long top_bit = N;

    uint32_t quo[8] = {0, 0, 0, 0, 0, 0, 0, 0}; // 256-bit quotient
    if (N < 0 || N >= 320 || top_bit >= 308) {
        // diff too small to represent -- clamp to maximum target.
        for (int i = 0; i < 32; ++i) target_msb[i] = 0xff;
        return;
    }

    uint64_t rem = 0;
    for (long long bit = top_bit; bit >= 0; --bit) {
        rem = (rem << 1) | ((num[bit / 32] >> (bit % 32)) & 1u);
        if (rem >= mant) {
            rem -= mant;
            quo[bit / 32] |= (1u << (bit % 32));
        }
    }

    // quo is the threshold as a 256-bit integer whose most significant bit is
    // at index (top_bit - log2(mant)) <= 255. The little-endian digest integer
    // convention reads digest[31] as the most significant byte, i.e. the
    // MSB-first byte layout is the reverse of the quotient's limb bytes.
    for (int i = 0; i < 32; ++i) {
        const uint32_t limb = quo[i / 4];          // limb i/4 holds bits [32*(i/4), ...)
        const uint32_t byte_idx = i % 4;           // byte within the limb, LSB first
        target_msb[31 - i] = static_cast<uint8_t>((limb >> (8 * byte_idx)) & 0xff);
    }
}

struct GpuResult {
    // Mapped memory shared with the device, same layout as the kernel's ctrl:
    // found flag, nonce, iterations low, iterations high.
    uint32_t *host_ctrl = nullptr;
    uint32_t *dev_ctrl = nullptr;

    int device_id = 0;
    int sm_count = 0;
    int blocks_per_grid = 0;
    int threads_per_block = 256; // overridable via ELEK_CUDA_TPB (benchmarking)
    static constexpr uint32_t NONCE_SPAN = 1u << 24; // per launch

    void init(int device) {
        int devices = 0;
        CUDA_CHECK(cudaGetDeviceCount(&devices));
        if (devices <= 0) throw std::runtime_error("No CUDA device found");
        if (device >= devices) {
            std::cerr << "Warning: cuda.device " << device << " >= device count "
                      << devices << ", using device 0.\n";
            device = 0;
        }
        device_id = device;
        CUDA_CHECK(cudaSetDevice(device));

        cudaDeviceProp prop{};
        CUDA_CHECK(cudaGetDeviceProperties(&prop, device));
        sm_count = prop.multiProcessorCount;

        // Launch geometry: keep the total thread count at sm_count * 1024
        // (Turing's per-SM thread limit) by splitting it over block sizes.
        // ELEK_CUDA_TPB overrides the block size for benchmarking; the grid
        // always targets 1024 threads per SM.
        int tpb = 256;
        if (const char *env = std::getenv("ELEK_CUDA_TPB"); env && *env) {
            tpb = std::atoi(env);
            tpb = std::max(64, std::min(1024, tpb));
            tpb -= tpb % 32;
        }
        threads_per_block = tpb;
        const int blocks_per_sm = std::max(1, 1024 / tpb);
        blocks_per_grid = sm_count * blocks_per_sm;

        CUDA_CHECK(cudaHostAlloc(&host_ctrl, 4 * sizeof(uint32_t), cudaHostAllocMapped));
        CUDA_CHECK(cudaHostGetDevicePointer(&dev_ctrl, host_ctrl, 0));
        std::memset(host_ctrl, 0, 4 * sizeof(uint32_t));

        static const uint32_t K[64] = {
            0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
            0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
            0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
            0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
            0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
            0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
            0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
            0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
            0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
            0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
            0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
        CUDA_CHECK(cudaMemcpyToSymbol(c_K, K, sizeof(K)));
    }

    ~GpuResult() {
        if (host_ctrl) cudaFreeHost(host_ctrl);
    }

    // Uploads midstate + the three fixed header words (64..75) + target and
    // resets the result block. Call once per job.
    void set_job(const uint32_t midstate[8], const uint8_t header_prefix76[76],
                 const uint8_t target_msb[32]) {
        host_ctrl[0] = 0; // clear found
        uint32_t b2w[3];
        auto be_word = [](const uint8_t *p) {
            return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                   (uint32_t(p[2]) << 8) | uint32_t(p[3]);
        };
        b2w[0] = be_word(header_prefix76 + 64);
        b2w[1] = be_word(header_prefix76 + 68);
        b2w[2] = be_word(header_prefix76 + 72);

        uint32_t target_words[8];
        for (int i = 0; i < 8; ++i) {
            target_words[i] = (uint32_t(target_msb[4 * i]) << 24) |
                              (uint32_t(target_msb[4 * i + 1]) << 16) |
                              (uint32_t(target_msb[4 * i + 2]) << 8) |
                              uint32_t(target_msb[4 * i + 3]);
        }

        CUDA_CHECK(cudaMemcpyToSymbol(c_midstate, midstate, 8 * sizeof(uint32_t)));
        CUDA_CHECK(cudaMemcpyToSymbol(c_b2w, b2w, 3 * sizeof(uint32_t)));
        CUDA_CHECK(cudaMemcpyToSymbol(c_target, target_words, 8 * sizeof(uint32_t)));
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    // Scans one [base, base + span) chunk. Returns true if a nonce was found
    // (host_ctrl[1] holds it). Updates hash accounting.
    bool scan_chunk(uint32_t base, uint32_t span) {
        host_ctrl[0] = 0;
        sha256d_scan_kernel<<<blocks_per_grid, threads_per_block>>>(base, span, dev_ctrl);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
        return host_ctrl[0] == 1;
    }

    // nTime rolling: patches only header bytes 68..71 (constant word c_b2w[1]).
    // The midstate covers header bytes 0..63, so this is the sole state change
    // needed to give the next sweep a fresh header. Host-order nTime in,
    // big-endian word out (same packing as set_job's be_word).
    void set_ntime(uint32_t ntime) {
        host_ctrl[0] = 0;
        const uint32_t be = ((ntime & 0xffu) << 24) | ((ntime & 0xff00u) << 8) |
                            ((ntime >> 8) & 0xff00u) | (ntime >> 24);
        CUDA_CHECK(cudaMemcpyToSymbol(c_b2w, &be, sizeof(be),
                                      1 * sizeof(uint32_t), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaDeviceSynchronize());
    }

    // Aborts a running kernel early (used when a new job arrived).
    void request_abort() { host_ctrl[0] = 2; }

    uint64_t consume_hashes() {
        // iterations accumulate across launches; read + reset both words.
        const uint64_t lo = host_ctrl[2];
        const uint64_t hi = host_ctrl[3];
        host_ctrl[2] = 0;
        host_ctrl[3] = 0;
        return (hi << 32) | lo;
    }

    std::string name() const {
        cudaDeviceProp prop{};
        cudaGetDeviceProperties(&prop, device_id);
        return std::string(prop.name) + " (" + std::to_string(sm_count) + " SMs)";
    }
};

// ---------------------------------------------------------------------------
// CPU worker pool (solo mode) -- the host cores mine alongside the GPU.
//
// Nonce-space partition: the GPU sweeps chunks [0, gpu_chunks); CPU thread i
// owns chunk (gpu_chunks + i). Every (header, nonce) pair is therefore hashed
// by exactly one worker. CPU threads hash with the same midstate trick as the
// GPU (sha256d_midstate -> SHA256_Transform), each thread rolls its own nTime
// once its chunk is exhausted (bounded by the template's maxtime), and every
// find is independently re-verified with plain OpenSSL sha256d before it is
// handed to the main loop for submission.
// ---------------------------------------------------------------------------

struct CpuJob {
    uint32_t midstate[8];
    uint8_t prefix[76];      // header bytes 0..75 with the job's base nTime
    uint8_t target_msb[32];  // MSB-first target, same layout as gpu.set_job
    uint32_t ntime_max;
};

class CpuPool {
public:
    static constexpr uint32_t CHUNK = 1u << 24;    // one chunk == GpuResult::NONCE_SPAN
    static constexpr uint32_t SUB_UNIT = 1u << 20; // job-change check cadence

    void start(int threads, uint32_t gpu_chunks, const CpuJob &job) {
        gpu_chunks_ = gpu_chunks;
        {
            std::lock_guard<std::mutex> lock(job_mu_);
            job_ = job;
        }
        job_gen_.store(1, std::memory_order_release);
        for (int i = 0; i < threads; ++i)
            workers_.emplace_back(&CpuPool::worker_loop, this, i);
        thread_count_ = threads;
    }

    // Publishes a new template (midstate/prefix/target); workers pick it up
    // within one SUB_UNIT of work.
    void set_job(const CpuJob &job) {
        std::lock_guard<std::mutex> lock(job_mu_);
        job_ = job;
        job_gen_.fetch_add(1, std::memory_order_release);
    }

    void stop() {
        quit_.store(true, std::memory_order_relaxed);
        for (auto &t : workers_) {
            if (t.joinable()) t.join();
        }
        workers_.clear();
    }

    // Returns true and the full 80-byte header of one pending CPU find.
    bool poll_find(uint8_t header80_out[80]) {
        if (!find_flag_.load(std::memory_order_acquire)) return false;
        std::lock_guard<std::mutex> lock(find_mu_);
        if (!find_flag_.exchange(0, std::memory_order_relaxed)) return false;
        std::memcpy(header80_out, find_header_, 80);
        return true;
    }

    uint64_t take_hashes() { return hashes_.exchange(0, std::memory_order_relaxed); }

    int thread_count() const { return thread_count_; }

private:
    void worker_loop(int idx) {
        CpuJob job{};
        uint64_t seen_gen = 0;
        bool have_job = false;
        uint32_t ntime = 0; // this thread's own rolling time (independent of the GPU's)
        const uint32_t chunk_base = (gpu_chunks_ + static_cast<uint32_t>(idx)) << 24;
        uint64_t cursor = 0;

        SHA256_CTX ctx;
        SHA256_Init(&ctx);
        uint8_t block2[64], block3[64], hash[32], header80[80];

        while (!quit_.load(std::memory_order_relaxed)) {
            if (!have_job || job_gen_.load(std::memory_order_acquire) != seen_gen) {
                std::lock_guard<std::mutex> lock(job_mu_);
                job = job_;
                seen_gen = job_gen_.load(std::memory_order_relaxed);
                have_job = true;
                ntime = static_cast<uint32_t>(job.prefix[68]) |
                        (static_cast<uint32_t>(job.prefix[69]) << 8) |
                        (static_cast<uint32_t>(job.prefix[70]) << 16) |
                        (static_cast<uint32_t>(job.prefix[71]) << 24);
                cursor = 0;
            }

            // block2 static part: prefix[64..75]; bytes 4..7 (nTime, this
            // thread's own) and bytes 12..15 (nonce) are patched below.
            std::memcpy(block2, job.prefix + 64, 12);
            block2[16] = 0x80;
            std::memset(block2 + 17, 0, 45);
            block2[62] = 0x02;
            block2[63] = 0x80;

            for (uint32_t k = 0; k < SUB_UNIT; ++k) {
                const uint32_t n = chunk_base + static_cast<uint32_t>(cursor) + k;
                block2[4] = static_cast<uint8_t>(ntime);
                block2[5] = static_cast<uint8_t>(ntime >> 8);
                block2[6] = static_cast<uint8_t>(ntime >> 16);
                block2[7] = static_cast<uint8_t>(ntime >> 24);
                block2[12] = static_cast<uint8_t>(n);
                block2[13] = static_cast<uint8_t>(n >> 8);
                block2[14] = static_cast<uint8_t>(n >> 16);
                block2[15] = static_cast<uint8_t>(n >> 24);

                std::memcpy(ctx.h, job.midstate, 8 * sizeof(uint32_t));
                SHA256_Transform(&ctx, block2);
                for (int i = 0; i < 8; ++i) {
                    block3[4 * i + 0] = static_cast<uint8_t>(ctx.h[i] >> 24);
                    block3[4 * i + 1] = static_cast<uint8_t>(ctx.h[i] >> 16);
                    block3[4 * i + 2] = static_cast<uint8_t>(ctx.h[i] >> 8);
                    block3[4 * i + 3] = static_cast<uint8_t>(ctx.h[i]);
                }
                block3[32] = 0x80;
                std::memset(block3 + 33, 0, 29);
                block3[62] = 0x01;
                block3[63] = 0x00;
                SHA256_Init(&ctx);
                SHA256_Transform(&ctx, block3);
                for (int i = 0; i < 8; ++i) {
                    hash[4 * i + 0] = static_cast<uint8_t>(ctx.h[i] >> 24);
                    hash[4 * i + 1] = static_cast<uint8_t>(ctx.h[i] >> 16);
                    hash[4 * i + 2] = static_cast<uint8_t>(ctx.h[i] >> 8);
                    hash[4 * i + 3] = static_cast<uint8_t>(ctx.h[i]);
                }

                if (hash_le_target(hash, job.target_msb)) {
                    std::memcpy(header80, job.prefix, 76);
                    header80[68] = block2[4];
                    header80[69] = block2[5];
                    header80[70] = block2[6];
                    header80[71] = block2[7];
                    header80[76] = block2[12];
                    header80[77] = block2[13];
                    header80[78] = block2[14];
                    header80[79] = block2[15];
                    // Independent re-verify via the plain OpenSSL path before
                    // reporting -- a bad midstate/nonce mapping must never
                    // reach the node.
                    uint8_t verify[32];
                    sha256d(header80, 80, verify);
                    if (hash_le_target(verify, job.target_msb)) {
                        std::lock_guard<std::mutex> lock(find_mu_);
                        std::memcpy(find_header_, header80, 80);
                        find_flag_.store(1, std::memory_order_release);
                    }
                }
            }

            cursor += SUB_UNIT;
            hashes_.fetch_add(SUB_UNIT, std::memory_order_relaxed);
            if (cursor >= CHUNK) {
                cursor = 0;
                if (ntime < job.ntime_max) {
                    ++ntime; // chunk exhausted under this header -- roll nTime
                } else {
                    // No rolling headroom left -- idle until the next job.
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
            }
        }
    }

    std::vector<std::thread> workers_;
    std::mutex job_mu_;
    CpuJob job_{};
    std::atomic<uint64_t> job_gen_{0};
    std::atomic<uint64_t> hashes_{0};
    std::atomic<int> find_flag_{0};
    std::mutex find_mu_;
    uint8_t find_header_[80] = {0};
    uint32_t gpu_chunks_ = 256;
    int thread_count_ = 0;
    std::atomic<bool> quit_{false};
};

// Reference GPU hash used by the selftest: returns device sha256d digests for
// `count` 80-byte headers (bytes MSB-first packed into 20 BE words each).
static void gpu_reference_sha256d(const std::vector<std::array<uint8_t, 80>> &headers,
                                  std::vector<std::array<uint8_t, 32>> &out) {
    const int count = static_cast<int>(headers.size());
    std::vector<uint32_t> packed(static_cast<size_t>(count) * 20);
    for (int i = 0; i < count; ++i) {
        for (int w = 0; w < 20; ++w) {
            const uint8_t *p = headers[static_cast<size_t>(i)].data() + 4 * w;
            packed[static_cast<size_t>(i) * 20 + w] =
                (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                (uint32_t(p[2]) << 8) | uint32_t(p[3]);
        }
    }

    uint32_t *dev_in = nullptr;
    uint32_t *dev_out = nullptr;
    CUDA_CHECK(cudaMalloc(&dev_in, packed.size() * sizeof(uint32_t)));
    CUDA_CHECK(cudaMalloc(&dev_out, static_cast<size_t>(count) * 8 * sizeof(uint32_t)));
    CUDA_CHECK(cudaMemcpy(dev_in, packed.data(), packed.size() * sizeof(uint32_t),
                          cudaMemcpyHostToDevice));

    const int threads = 256;
    const int blocks = (count + threads - 1) / threads;
    sha256d_reference_kernel<<<blocks, threads>>>(dev_in, dev_out, count);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    std::vector<uint32_t> host_out(static_cast<size_t>(count) * 8);
    CUDA_CHECK(cudaMemcpy(host_out.data(), dev_out, host_out.size() * sizeof(uint32_t),
                          cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaFree(dev_in));
    CUDA_CHECK(cudaFree(dev_out));

    out.resize(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
        for (int w = 0; w < 8; ++w) {
            const uint32_t word = host_out[static_cast<size_t>(i) * 8 + w];
            out[static_cast<size_t>(i)][4 * w] = (word >> 24) & 0xff;
            out[static_cast<size_t>(i)][4 * w + 1] = (word >> 16) & 0xff;
            out[static_cast<size_t>(i)][4 * w + 2] = (word >> 8) & 0xff;
            out[static_cast<size_t>(i)][4 * w + 3] = word & 0xff;
        }
    }
}

// Runs the three selftests + a short benchmark. Throws on any failure.
static void run_selftest(GpuResult &gpu) {
    std::cout << "Selftest on " << gpu.name() << "\n";

    // --- 1. GPU digest == OpenSSL digest for random headers ---
    std::vector<std::array<uint8_t, 80>> headers;
    std::vector<std::array<uint8_t, 32>> expected;
    uint64_t rng = 0x9e3779b97f4a7c15ull;
    auto next_byte = [&rng]() {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        return static_cast<uint8_t>(rng & 0xff);
    };
    for (int i = 0; i < 4096; ++i) {
        std::array<uint8_t, 80> h{};
        for (auto &b : h) b = next_byte();
        headers.push_back(h);
        std::array<uint8_t, 32> d{};
        sha256d(h.data(), 80, d.data());
        expected.push_back(d);
    }
    std::vector<std::array<uint8_t, 32>> got;
    gpu_reference_sha256d(headers, got);
    size_t mismatches = 0;
    for (size_t i = 0; i < headers.size(); ++i) {
        if (got[i] != expected[i]) ++mismatches;
    }
    if (mismatches != 0) {
        throw std::runtime_error("Selftest 1 FAILED: " + std::to_string(mismatches) +
                                 "/4096 GPU sha256d digests differ from OpenSSL");
    }
    std::cout << "  1. sha256d vs OpenSSL:      4096/4096 identical\n";

    // --- 2. known-nonce scan: target = digest of a chosen nonce ---
    uint32_t header_prefix[19] = {0}; // 76 bytes as words (19 x 4 bytes)
    for (int i = 0; i < 19; ++i) {
        for (int b = 0; b < 4; ++b) {
            reinterpret_cast<uint8_t *>(header_prefix)[4 * i + b] = next_byte();
        }
    }
    const uint32_t target_nonce = 0x00ABCDEFu;
    uint8_t header80[80];
    std::memcpy(header80, header_prefix, 76);
    header80[76] = target_nonce & 0xff;
    header80[77] = (target_nonce >> 8) & 0xff;
    header80[78] = (target_nonce >> 16) & 0xff;
    header80[79] = (target_nonce >> 24) & 0xff;

    uint8_t target[32];
    sha256d(header80, 80, target);
    // set_job expects the target MSB-first (byte 0 = most significant byte of
    // the little-endian digest integer), i.e. the REVERSE of the digest bytes.
    uint8_t target_msb[32];
    for (int i = 0; i < 32; ++i) target_msb[i] = target[31 - i];

    uint32_t midstate[8];
    sha256_midstate(header80, midstate);
    gpu.set_job(midstate, header80, target_msb);

    const uint32_t window_base = target_nonce - 1000;
    // The target is the full 256-bit digest of the chosen nonce, so roughly
    // half of all nonces qualify (the chosen nonce itself qualifies via the
    // equal-digest fall-through and is guaranteed inside the window). The
    // kernel reports whichever nonce wins the CAS race; the deterministic
    // checks are: (a) something is found in the window, (b) the reported
    // nonce's digest beats the target on the CPU, (c) the reported nonce
    // lies inside the window.
    if (!gpu.scan_chunk(window_base, 2000)) {
        throw std::runtime_error("Selftest 2 FAILED: no nonce found in known-nonce window");
    }
    const uint32_t found_nonce = gpu.host_ctrl[1];
    if (found_nonce < window_base || found_nonce - window_base >= 2000) {
        throw std::runtime_error("Selftest 2 FAILED: reported nonce outside the window (nonce=" +
                                 std::to_string(found_nonce) + ")");
    }
    uint8_t found_header[80];
    std::memcpy(found_header, header_prefix, 76);
    found_header[76] = found_nonce & 0xff;
    found_header[77] = (found_nonce >> 8) & 0xff;
    found_header[78] = (found_nonce >> 16) & 0xff;
    found_header[79] = (found_nonce >> 24) & 0xff;
    uint8_t found_hash[32];
    sha256d(found_header, 80, found_hash);
    if (!hash_le_target(found_hash, target_msb)) {
        throw std::runtime_error("Selftest 2 FAILED: CPU re-verify rejected the reported nonce (nonce=" +
                                 std::to_string(found_nonce) + ")");
    }
    std::cout << "  2. known-nonce scan:        nonce 0x" << std::hex << found_nonce
              << std::dec << " found in window and CPU-verified\n";

    // --- 3. difficulty -> target sanity ---
    uint8_t t1[32], t2[32], t3[32];
    difficulty_to_target_be(1.0, t1);
    difficulty_to_target_be(0.001, t2);
    difficulty_to_target_be(65536.0, t3);
    auto msb_log2 = [](const uint8_t t[32]) {
        for (int i = 0; i < 32; ++i)
            if (t[i]) return 31 - __builtin_clz(static_cast<uint32_t>(t[i])) + 8 * (31 - i);
        return -1;
    };
    const int l1 = msb_log2(t1), l2 = msb_log2(t2), l3 = msb_log2(t3);
    // diff 1 -> 2^224 (bit 224), diff 0.001 -> ~2^234, diff 65536 -> ~2^208.
    if (l1 < 223 || l1 > 224 || l2 < 233 || l2 > 235 || l3 < 207 || l3 > 209) {
        throw std::runtime_error("Selftest 3 FAILED: unexpected target magnitudes " +
                                 std::to_string(l1) + "/" + std::to_string(l2) + "/" +
                                 std::to_string(l3));
    }
    std::cout << "  3. difficulty->target:      diff1=2^" << l1 << " diff0.001=2^" << l2
              << " diff65536=2^" << l3 << " (expected 224/234/208)\n";

    // --- 4. benchmark ---
    uint8_t zero_target[32];
    std::memset(zero_target, 0, 32);
    gpu.set_job(midstate, header80, zero_target); // never finds -- pure throughput
    gpu.host_ctrl[2] = 0;
    gpu.host_ctrl[3] = 0;
    const uint32_t sweep = GpuResult::NONCE_SPAN;
    const auto t_start = std::chrono::steady_clock::now();
    uint64_t done = 0;
    do {
        gpu.scan_chunk(0x40000000u, sweep);
        done += sweep;
    } while (std::chrono::steady_clock::now() - t_start < std::chrono::seconds(3));
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();
    const double hps = static_cast<double>(gpu.consume_hashes()) / secs;
    std::cout << "  4. benchmark:               " << std::fixed << std::setprecision(2)
              << hps / 1e9 << " GH/s over " << secs << " s (" << done / 1000000 << "M nonces)\n";
    std::cout.unsetf(std::ios::fixed);

    // --- 5. CPU midstate path (SHA256_Transform) == plain sha256d ---
    size_t cpu_mismatches = 0;
    for (size_t i = 0; i < 512; ++i) {
        uint32_t ms[8];
        sha256_midstate(headers[i].data(), ms);
        uint8_t out[32];
        sha256d_midstate(ms, headers[i].data(), out);
        if (std::memcmp(out, expected[i].data(), 32) != 0) ++cpu_mismatches;
    }
    if (cpu_mismatches != 0) {
        throw std::runtime_error("Selftest 5 FAILED: " + std::to_string(cpu_mismatches) +
                                 "/512 CPU midstate digests differ from OpenSSL");
    }
    std::cout << "  5. CPU midstate path:       512/512 identical\n";

    // --- 6. CPU single-thread throughput ---
    uint32_t cpu_ms[8];
    sha256_midstate(headers[0].data(), cpu_ms);
    uint8_t cpu_out[32];
    uint64_t cpu_done = 0;
    const auto cpu_start = std::chrono::steady_clock::now();
    do {
        for (int k = 0; k < 4096; ++k) {
            sha256d_midstate(cpu_ms, headers[static_cast<size_t>(k) % 512].data(), cpu_out);
        }
        cpu_done += 4096;
    } while (std::chrono::steady_clock::now() - cpu_start < std::chrono::seconds(1));
    const double cpu_secs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - cpu_start).count();
    std::cout << "  6. CPU thread benchmark:    " << std::fixed << std::setprecision(2)
              << static_cast<double>(cpu_done) / 1e6 / cpu_secs
              << " MH/s per thread (midstate path)\n";
    std::cout.unsetf(std::ios::fixed);

    // --- 7. CPU worker: CpuPool finds, re-verifies and reports a nonce ---
    // Reuses the selftest-2 job (prefix / midstate / target_msb) with a
    // target tightened by 17 bits, so only ~2^-17 of all digests qualify --
    // a broken nonce->header mapping would pass the worker's re-verify with
    // probability ~2^-17 instead of ~1/2. Two workers start with gpu_chunks
    // = 0, i.e. worker 0 owns chunk 0 ([0, 2^24)) and worker 1 chunk 1. The
    // checks: poll_find() returns a header within 10 s, its digest beats the
    // tightened target on the plain OpenSSL path, and its nonce lies inside
    // the worker chunk range.
    uint8_t strict_msb[32] = {0};
    constexpr int shift = 17, byte_sh = shift / 8, bit_sh = shift % 8;
    for (int i = 0; i + byte_sh < 32; ++i) {
        uint32_t acc = static_cast<uint32_t>(target_msb[i + byte_sh]) >> bit_sh;
        if (i + byte_sh + 1 < 32)
            acc |= static_cast<uint32_t>(target_msb[i + byte_sh + 1]) << (8 - bit_sh);
        strict_msb[i] = static_cast<uint8_t>(acc);
    }
    CpuJob cpu_job{};
    std::memcpy(cpu_job.midstate, midstate, sizeof(cpu_job.midstate));
    std::memcpy(cpu_job.prefix, header80, 76);
    std::memcpy(cpu_job.target_msb, strict_msb, 32);
    cpu_job.ntime_max = static_cast<uint32_t>(header80[68]) |
                        (static_cast<uint32_t>(header80[69]) << 8) |
                        (static_cast<uint32_t>(header80[70]) << 16) |
                        (static_cast<uint32_t>(header80[71]) << 24);

    CpuPool cpu_test;
    cpu_test.start(2, 0, cpu_job);
    uint8_t worker_header[80] = {0};
    bool worker_found = false;
    const auto worker_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (std::chrono::steady_clock::now() < worker_deadline) {
        if (cpu_test.poll_find(worker_header)) {
            worker_found = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    cpu_test.stop();
    if (!worker_found) {
        throw std::runtime_error("Selftest 7 FAILED: CPU workers produced no qualifying nonce in 15 s");
    }
    const uint32_t worker_nonce = static_cast<uint32_t>(worker_header[76]) |
                                  (static_cast<uint32_t>(worker_header[77]) << 8) |
                                  (static_cast<uint32_t>(worker_header[78]) << 16) |
                                  (static_cast<uint32_t>(worker_header[79]) << 24);
    if (worker_nonce >= (1u << 25)) {
        throw std::runtime_error("Selftest 7 FAILED: reported nonce 0x" +
                                 std::to_string(worker_nonce) + " outside worker chunks 0/1");
    }
    uint8_t worker_hash[32];
    sha256d(worker_header, 80, worker_hash);
    if (!hash_le_target(worker_hash, strict_msb)) {
        throw std::runtime_error("Selftest 7 FAILED: re-verify rejected the CPU worker find");
    }
    std::cout << "  7. CPU worker scan:         nonce 0x" << std::hex << worker_nonce
              << std::dec << " found, re-verified and polled\n";
}

// ---------------------------------------------------------------------------
// Pool (Stratum V1) client -- ported verbatim from miner.cpp
// ---------------------------------------------------------------------------

#if defined(_WIN32)
using socket_t = SOCKET;
static const socket_t INVALID_SOCK = INVALID_SOCKET;
static void close_socket(socket_t s) { closesocket(s); }
#else
using socket_t = int;
static const socket_t INVALID_SOCK = -1;
static void close_socket(socket_t s) { close(s); }
#endif

static socket_t tcp_connect(const std::string &host, const std::string &port) {
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *res = nullptr;
    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0 || res == nullptr) {
        throw std::runtime_error("DNS/address resolution failed for " + host + ":" + port);
    }

    socket_t sock = INVALID_SOCK;
    for (struct addrinfo *p = res; p != nullptr; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock == INVALID_SOCK) continue;
        if (connect(sock, p->ai_addr, static_cast<int>(p->ai_addrlen)) == 0) break;
        close_socket(sock);
        sock = INVALID_SOCK;
    }
    freeaddrinfo(res);

    if (sock == INVALID_SOCK) {
        throw std::runtime_error("Could not connect to " + host + ":" + port);
    }
    return sock;
}

static void socket_send_line(socket_t sock, const std::string &line) {
    std::string data = line;
    if (data.empty() || data.back() != '\n') data += '\n';
    size_t sent_total = 0;
    while (sent_total < data.size()) {
        const int n = send(sock, data.data() + sent_total, static_cast<int>(data.size() - sent_total), 0);
        if (n <= 0) throw std::runtime_error("send() failed -- connection lost");
        sent_total += static_cast<size_t>(n);
    }
}

class LineReader {
public:
    explicit LineReader(socket_t sock) : sock_(sock) {}

    std::string next_line() {
        for (;;) {
            const size_t pos = buffer_.find('\n');
            if (pos != std::string::npos) {
                std::string line = buffer_.substr(0, pos);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                buffer_.erase(0, pos + 1);
                return line;
            }
            char chunk[4096];
            const int n = recv(sock_, chunk, sizeof(chunk), 0);
            if (n <= 0) throw std::runtime_error("Connection closed by pool");
            buffer_.append(chunk, static_cast<size_t>(n));
        }
    }

private:
    socket_t sock_;
    std::string buffer_;
};

static bool parse_stratum_url(const std::string &url, std::string &host, std::string &port) {
    std::string s = url;
    const std::string tcp_prefix = "stratum+tcp://";
    if (s.rfind(tcp_prefix, 0) == 0) {
        s = s.substr(tcp_prefix.size());
    } else if (s.rfind("stratum+ssl://", 0) == 0 || s.rfind("stratum+tls://", 0) == 0) {
        std::cerr << "ERROR: this miner does not support TLS Stratum (stratum+ssl/tls://). "
                     "Use the plain stratum+tcp:// URL instead.\n";
        return false;
    }
    const size_t slash = s.find('/');
    if (slash != std::string::npos) s = s.substr(0, slash);
    const size_t colon = s.rfind(':');
    if (colon == std::string::npos) return false;
    host = s.substr(0, colon);
    port = s.substr(colon + 1);
    return !host.empty() && !port.empty();
}

static std::string extract_top_array_body(const std::string &json, const std::string &key) {
    const std::string quoted = "\"" + key + "\"";
    size_t pos = json.find(quoted);
    if (pos == std::string::npos) return "";
    pos = json.find('[', pos);
    if (pos == std::string::npos) return "";
    int depth = 0;
    for (size_t i = pos; i < json.size(); ++i) {
        if (json[i] == '[') ++depth;
        else if (json[i] == ']') {
            --depth;
            if (depth == 0) return json.substr(pos + 1, i - pos - 1);
        }
    }
    return "";
}

static std::vector<std::string> split_json_array(const std::string &arr) {
    std::vector<std::string> out;
    int depth = 0;
    bool in_string = false;
    size_t start = 0;
    for (size_t i = 0; i < arr.size(); ++i) {
        const char c = arr[i];
        if (in_string) {
            if (c == '\\') { ++i; continue; }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') { in_string = true; continue; }
        if (c == '[' || c == '{') { ++depth; continue; }
        if (c == ']' || c == '}') { --depth; continue; }
        if (c == ',' && depth == 0) {
            out.push_back(arr.substr(start, i - start));
            start = i + 1;
        }
    }
    if (start <= arr.size()) out.push_back(arr.substr(start));
    for (auto &s : out) {
        const size_t a = s.find_first_not_of(" \t\r\n");
        const size_t b = s.find_last_not_of(" \t\r\n");
        s = (a == std::string::npos) ? "" : s.substr(a, b - a + 1);
    }
    if (out.size() == 1 && out[0].empty()) out.clear();
    return out;
}

static std::string strip_quotes(const std::string &s) {
    if (s.size() >= 2 && s.front() == '"' && s.back() == '"') {
        std::string out;
        out.reserve(s.size());
        for (size_t i = 1; i + 1 < s.size(); ++i) {
            if (s[i] == '\\' && i + 2 < s.size()) { out.push_back(s[i + 1]); ++i; }
            else out.push_back(s[i]);
        }
        return out;
    }
    return s;
}

static std::vector<uint8_t> swap_endian_words(const std::vector<uint8_t> &in) {
    std::vector<uint8_t> out(in.size());
    for (size_t i = 0; i + 3 < in.size(); i += 4) {
        out[i] = in[i + 3];
        out[i + 1] = in[i + 2];
        out[i + 2] = in[i + 1];
        out[i + 3] = in[i];
    }
    return out;
}

struct StratumJob {
    std::string job_id;
    std::vector<uint8_t> prev_hash;
    std::vector<uint8_t> coinbase;
    std::vector<std::vector<uint8_t>> merkle_branch;
    uint32_t version = 0;
    uint32_t bits = 0;
    uint32_t ntime = 0;
    bool clean_jobs = false;
};

static StratumJob parse_mining_notify(const std::string &line) {
    const std::string params_body = extract_top_array_body(line, "params");
    const auto fields = split_json_array(params_body);
    if (fields.size() < 9) throw std::runtime_error("mining.notify: expected 9 params, got " + std::to_string(fields.size()));

    StratumJob job;
    job.job_id = strip_quotes(fields[0]);
    job.prev_hash = swap_endian_words(hex_decode(strip_quotes(fields[1])));

    const std::string coinb1 = strip_quotes(fields[2]);
    const std::string coinb2 = strip_quotes(fields[3]);
    job.coinbase = hex_decode(coinb1 + coinb2);

    const std::string &branch_field = fields[4];
    const std::string branch_body = branch_field.size() >= 2 ? branch_field.substr(1, branch_field.size() - 2) : "";
    for (const auto &raw : split_json_array(branch_body)) {
        job.merkle_branch.push_back(hex_decode(strip_quotes(raw)));
    }

    job.version = static_cast<uint32_t>(std::stoul(strip_quotes(fields[5]), nullptr, 16));
    job.bits = static_cast<uint32_t>(std::stoul(strip_quotes(fields[6]), nullptr, 16));
    job.ntime = static_cast<uint32_t>(std::stoul(strip_quotes(fields[7]), nullptr, 16));
    job.clean_jobs = fields[8].find("true") != std::string::npos;
    return job;
}

static double parse_set_difficulty(const std::string &line) {
    const std::string params_body = extract_top_array_body(line, "params");
    const auto fields = split_json_array(params_body);
    if (fields.empty()) return 1.0;
    return std::stod(fields[0]);
}

static void apply_merkle_branch(uint8_t root[32], const std::vector<std::vector<uint8_t>> &branch) {
    for (const auto &node : branch) {
        uint8_t combined[64];
        std::memcpy(combined, root, 32);
        std::memset(combined + 32, 0, 32);
        std::memcpy(combined + 32, node.data(), std::min<size_t>(32, node.size()));
        sha256d(combined, 64, root);
    }
}

static std::vector<uint8_t> build_stratum_header_prefix(const StratumJob &job, const uint8_t merkle_root[32]) {
    std::vector<uint8_t> header(80, 0);
    header[0] = static_cast<uint8_t>(job.version & 0xff);
    header[1] = static_cast<uint8_t>((job.version >> 8) & 0xff);
    header[2] = static_cast<uint8_t>((job.version >> 16) & 0xff);
    header[3] = static_cast<uint8_t>((job.version >> 24) & 0xff);

    std::memcpy(header.data() + 4, job.prev_hash.data(), std::min<size_t>(32, job.prev_hash.size()));
    std::memcpy(header.data() + 36, merkle_root, 32);

    header[68] = static_cast<uint8_t>(job.ntime & 0xff);
    header[69] = static_cast<uint8_t>((job.ntime >> 8) & 0xff);
    header[70] = static_cast<uint8_t>((job.ntime >> 16) & 0xff);
    header[71] = static_cast<uint8_t>((job.ntime >> 24) & 0xff);

    header[72] = static_cast<uint8_t>(job.bits & 0xff);
    header[73] = static_cast<uint8_t>((job.bits >> 8) & 0xff);
    header[74] = static_cast<uint8_t>((job.bits >> 16) & 0xff);
    header[75] = static_cast<uint8_t>((job.bits >> 24) & 0xff);
    return header;
}

static const double TRUE_DIFF_ONE = 2.695953529101131e67;

static double hash_to_difficulty(const uint8_t hash[32]) {
    double value = 0.0;
    for (int i = 31; i >= 0; --i) {
        value = value * 256.0 + hash[i];
    }
    if (value == 0.0) return std::numeric_limits<double>::infinity();
    return TRUE_DIFF_ONE / value;
}

struct SharedJobState {
    std::mutex mutex;
    StratumJob job;
    bool has_job = false;
    double difficulty = 1.0;
    std::atomic<uint64_t> generation{0};
};

static void submit_share(socket_t sock, std::mutex &send_mutex, std::atomic<int> &submit_id,
                          const std::string &user, const std::string &job_id,
                          uint32_t ntime, uint32_t nonce) {
    auto to_hex8 = [](uint32_t v) {
        std::ostringstream t;
        t << std::hex << std::setfill('0') << std::setw(8) << v;
        return t.str();
    };

    const int id = submit_id.fetch_add(1);
    std::ostringstream msg;
    msg << "{\"id\":" << id << ",\"method\":\"mining.submit\",\"params\":["
        << json_quote_string(user) << ","
        << json_quote_string(job_id) << ","
        << json_quote_string("") << ","
        << json_quote_string(to_hex8(ntime)) << ","
        << json_quote_string(to_hex8(nonce))
        << "]}";

    std::lock_guard<std::mutex> lock(send_mutex);
    socket_send_line(sock, msg.str());
}

static void pool_network_thread(LineReader &reader, SharedJobState &state, std::atomic<bool> &stop_all) {
    try {
        for (;;) {
            const std::string line = reader.next_line();
            if (line.find("\"method\":\"mining.notify\"") != std::string::npos) {
                StratumJob job = parse_mining_notify(line);
                const std::string job_id = job.job_id;
                const bool clean = job.clean_jobs;
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    state.job = std::move(job);
                    state.has_job = true;
                }
                state.generation.fetch_add(1);
                std::cout << "New job " << job_id << " (clean_jobs=" << (clean ? "true" : "false") << ")\n";
            } else if (line.find("\"method\":\"mining.set_difficulty\"") != std::string::npos) {
                const double diff = parse_set_difficulty(line);
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    state.difficulty = diff;
                }
                state.generation.fetch_add(1); // retarget => re-derive target
                std::cout << "Difficulty set to " << diff << "\n";
            } else if (line.find("\"result\":true") != std::string::npos) {
                std::cout << "Share accepted.\n";
            } else if (line.find("\"error\":null") == std::string::npos) {
                std::cout << "Pool: " << line << "\n";
            }
        }
    } catch (const std::exception &e) {
        std::cerr << "Pool connection lost: " << e.what() << "\n";
    }
    stop_all.store(true);
}

// The GPU analogue of miner.cpp's CPU pool_mine_thread: watches SharedJobState
// and keeps the device scanning nonce chunks of the current job.
static void pool_gpu_mine_thread(SharedJobState &state,
                                 socket_t sock, std::mutex &send_mutex, const std::string &user,
                                 std::atomic<int> &submit_id, std::atomic<bool> &stop_all,
                                 GpuResult &gpu, std::atomic<uint64_t> &hash_total) {
    uint64_t last_seen_generation = static_cast<uint64_t>(-1);
    StratumJob local_job;
    double local_diff = 1.0;

    while (!stop_all.load()) {
        const uint64_t gen = state.generation.load();
        if (gen != last_seen_generation) {
            bool have_job;
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                have_job = state.has_job;
                if (have_job) {
                    local_job = state.job;
                    local_diff = state.difficulty;
                }
            }
            if (!have_job) {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                continue;
            }
            last_seen_generation = gen;

            uint8_t merkle_root[32];
            sha256d(local_job.coinbase.data(), local_job.coinbase.size(), merkle_root);
            apply_merkle_branch(merkle_root, local_job.merkle_branch);

            const std::vector<uint8_t> header_prefix = build_stratum_header_prefix(local_job, merkle_root);

            uint8_t target[32];
            difficulty_to_target_be(local_diff, target);

            uint32_t midstate[8];
            sha256_midstate(header_prefix.data(), midstate);
            gpu.set_job(midstate, header_prefix.data(), target);
        }

        gpu.scan_chunk(0, GpuResult::NONCE_SPAN);
        hash_total.fetch_add(gpu.consume_hashes());

        if (gpu.host_ctrl[0] == 1) {
            const uint32_t nonce = gpu.host_ctrl[1];
            uint8_t header80[80];
            {
                uint8_t merkle_root[32];
                sha256d(local_job.coinbase.data(), local_job.coinbase.size(), merkle_root);
                apply_merkle_branch(merkle_root, local_job.merkle_branch);
                const std::vector<uint8_t> prefix = build_stratum_header_prefix(local_job, merkle_root);
                std::memcpy(header80, prefix.data(), 76);
            }
            header80[76] = nonce & 0xff;
            header80[77] = (nonce >> 8) & 0xff;
            header80[78] = (nonce >> 16) & 0xff;
            header80[79] = (nonce >> 24) & 0xff;

            uint8_t hash[32];
            sha256d(header80, 80, hash);
            if (hash_to_difficulty(hash) >= local_diff) {
                std::cout << "Share found! job=" << local_job.job_id << " nonce=" << std::hex
                          << nonce << std::dec << " diff=" << hash_to_difficulty(hash) << "\n";
                submit_share(sock, send_mutex, submit_id, user, local_job.job_id, local_job.ntime, nonce);
            }
            // else: stale/aborted chunk raced a job change -- discard.
        }
    }
}

static int run_pool_mode(const Config &cfg, GpuResult &gpu, std::atomic<uint64_t> &hash_total) {
    std::string host, port;
    if (!parse_stratum_url(cfg.pool_url, host, port)) {
        std::cerr << "ERROR: could not parse pool.url '" << cfg.pool_url
                   << "' (expected stratum+tcp://host:port/)\n";
        return 1;
    }

    do {
        try {
            std::cout << "\nConnecting to " << host << ":" << port << "...\n";
            socket_t sock = tcp_connect(host, port);
            std::mutex send_mutex;
            LineReader reader(sock);

            {
                std::lock_guard<std::mutex> lock(send_mutex);
                socket_send_line(sock, "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"elektron_miner_cuda/1.0\"]}");
            }
            const std::string subscribe_response = reader.next_line();
            std::cout << "Subscribe response: " << subscribe_response << "\n";

            {
                std::ostringstream auth;
                auth << "{\"id\":2,\"method\":\"mining.authorize\",\"params\":["
                     << json_quote_string(cfg.pool_user) << ","
                     << json_quote_string(cfg.pool_password) << "]}";
                std::lock_guard<std::mutex> lock(send_mutex);
                socket_send_line(sock, auth.str());
            }
            const std::string authorize_response = reader.next_line();
            std::cout << "Authorize response: " << authorize_response << "\n";
            if (authorize_response.find("\"result\":true") == std::string::npos) {
                std::cerr << "ERROR: Authorization rejected. pool.user must be "
                             "\"<your Elektron address>.<worker name>\" -- check the address is valid.\n";
                close_socket(sock);
                if (!cfg.continuous) return 1;
                std::this_thread::sleep_for(std::chrono::seconds(5));
                continue;
            }
            std::cout << "Authorized. Waiting for work...\n";

            SharedJobState state;
            std::atomic<int> submit_id{100};
            std::atomic<bool> stop_all{false};

            std::thread net_thread(pool_network_thread, std::ref(reader), std::ref(state), std::ref(stop_all));

            std::thread gpu_thread(pool_gpu_mine_thread, std::ref(state), sock,
                                   std::ref(send_mutex), std::cref(cfg.pool_user),
                                   std::ref(submit_id), std::ref(stop_all), std::ref(gpu),
                                   std::ref(hash_total));

            net_thread.join();
            stop_all.store(true);
            gpu.request_abort();
            gpu_thread.join();
            close_socket(sock);
        } catch (const std::exception &e) {
            std::cerr << "Pool mode error: " << e.what() << "\n";
        }

        if (!cfg.continuous) break;
        std::cout << "Reconnecting in 5 seconds...\n";
        std::this_thread::sleep_for(std::chrono::seconds(5));
    } while (true);

    return 0;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char *argv[]) {
#if defined(_WIN32)
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

    // Arg handling: [--selftest|--noselftest] [config.json]
    bool do_selftest = true;
    std::string config_path = "config.json";
    bool selftest_only = false;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--selftest") { do_selftest = true; selftest_only = true; }
        else if (arg == "--noselftest") do_selftest = false;
        else config_path = arg;
    }

    Config cfg;
    cfg.load(config_path);

    std::cout << "Elektron Net GPU Miner (CUDA)\n";

    curl_global_init(CURL_GLOBAL_DEFAULT);

    GpuResult gpu;
    std::atomic<uint64_t> hash_total{0};
    try {
        gpu.init(cfg.cuda_device);
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << "\n";
        return 1;
    }
    std::cout << "Device:  " << gpu.name() << "\n";

    if (do_selftest) {
        try {
            run_selftest(gpu);
        } catch (const std::exception &e) {
            std::cerr << "\n" << e.what() << "\n";
            std::cerr << "Refusing to mine -- fix the selftest failure first.\n";
            return 1;
        }
        if (selftest_only) return 0;
    }

    if (cfg.pool_enabled) {
        std::cout << "Mode:    Pool (Stratum V1)\n";
        std::cout << "Pool:    " << cfg.pool_url << "\n";
        std::cout << "User:    " << cfg.pool_user << "\n";
        return run_pool_mode(cfg, gpu, hash_total);
    }

    if (cfg.mining_address.empty()) {
        std::cerr << "ERROR: No payout address. Set mining.address in config.json.\n";
        return 1;
    }

    std::cout << "Mode:    Solo (RPC)\n";
    std::cout << "RPC:     " << cfg.rpc_url << "\n";
    std::cout << "Address: " << cfg.mining_address << "\n";

    RpcClient rpc(cfg.rpc_url, cfg.rpc_user, cfg.rpc_password);

    std::vector<uint8_t> script_pubkey;
    try {
        script_pubkey = address_to_scriptpubkey(rpc, cfg.mining_address);
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << "\n";
        return 1;
    }

    uint8_t target[32] = {0};

    // Persistent job state across template fetches, enabling nTime rolling:
    // a full sweep covers the whole 2^32 nonce space in seconds while a
    // template stays valid ~60 s. When a refetched template is byte-identical
    // to the current job (nTime excepted), rolling nTime produces a fresh
    // header instead of re-scanning the same one.
    bool have_job = false;
    uint8_t prefix_saved[76] = {0};
    uint32_t ntime_current = 0;
    uint32_t base_curtime = 0;
    uint32_t ntime_max = 0;
    int height_current = 0;

    // CPU worker pool: mining.threads (or cpu.threads) host threads mine
    // alongside the GPU on the chunks above the GPU's nonce range.
    CpuPool cpu_pool;
    int cpu_threads = cfg.cpu_threads >= 0 ? cfg.cpu_threads : cfg.threads;
    if (const unsigned hc = std::thread::hardware_concurrency();
        hc > 0 && cpu_threads > static_cast<int>(hc)) {
        cpu_threads = static_cast<int>(hc);
    }
    if (cpu_threads > 128) cpu_threads = 128;
    const uint32_t gpu_chunks =
        cpu_threads > 0 ? 256u - static_cast<uint32_t>(cpu_threads) : 256u;
    if (cpu_threads > 0) {
        std::cout << "CPU workers: " << cpu_threads << " thread(s) on chunks "
                  << gpu_chunks << "..255; GPU covers chunks 0.." << (gpu_chunks - 1) << "\n";
    }

    // Shared submit path for GPU and CPU finds: re-verify the digest, then
    // submit the block assembled from the exact header that was mined.
    auto submit_header = [&](const BlockTemplate &tmpl, const uint8_t header80[80],
                             const std::vector<uint8_t> &coinbase_tx, const char *source) {
        uint8_t hash[32];
        sha256d(header80, 80, hash);
        if (!hash_le_target(hash, target)) {
            std::cerr << source << " hit rejected by CPU re-verify -- "
                         "run --selftest before mining.\n";
            return false;
        }
        const uint32_t nonce = static_cast<uint32_t>(header80[76]) |
                               (static_cast<uint32_t>(header80[77]) << 8) |
                               (static_cast<uint32_t>(header80[78]) << 16) |
                               (static_cast<uint32_t>(header80[79]) << 24);
        std::cout << "Submitting block from " << source << " (nonce=" << nonce << ")\n";
        const std::string block_hex = assemble_block_hex(tmpl, header80, coinbase_tx);
        const std::string submit_resp = rpc.call("submitblock", {json_quote_string(block_hex)});
        if (submit_resp.find("\"result\":null") != std::string::npos ||
            submit_resp.find("\"result\": null") != std::string::npos) {
            std::cout << "Block accepted.\n";
            return true;
        }
        if (const std::string reject = extract_json_string(submit_resp, "result"); !reject.empty()) {
            std::cout << "Block submit result: " << reject << "\n";
        } else {
            std::cout << "Submit response: " << submit_resp << "\n";
        }
        return false;
    };

    do {
        try {
            std::cout << "\nFetching block template...\n";
            const std::string gbt_params =
                "{\"rules\":[\"segwit\"],\"coinbaseaddress\":\"" + cfg.mining_address + "\"}";
            const std::string tmpl_json = rpc.call("getblocktemplate", {gbt_params});

            if (tmpl_json.find("\"error\":") != std::string::npos &&
                tmpl_json.find("\"error\":null") == std::string::npos &&
                tmpl_json.find("\"error\": null") == std::string::npos) {
                std::cerr << "RPC error: " << tmpl_json << "\n";
                std::this_thread::sleep_for(std::chrono::seconds(5));
                continue;
            }

            BlockTemplate tmpl = parse_template(tmpl_json);
            if (tmpl.bits == 0 || tmpl.height <= 0) {
                std::cerr << "Failed to parse block template.\n";
                std::this_thread::sleep_for(std::chrono::seconds(5));
                continue;
            }

            if (tmpl.required_outputs.empty()) {
                std::cerr << "WARNING: Template has no coinbase_required_outputs — block would be invalid.\n";
            } else {
                std::cout << "Required coinbase outputs: " << tmpl.required_outputs.size() << "\n";
            }

            std::vector<uint8_t> coinbase_tx;
            std::vector<uint8_t> coinbase_no_witness;
            build_coinbase_tx(tmpl, script_pubkey, coinbase_tx, coinbase_no_witness);

            uint8_t coinbase_txid[32];
            sha256d(coinbase_no_witness.data(), coinbase_no_witness.size(), coinbase_txid);

            std::vector<std::vector<uint8_t>> merkle_hashes;
            merkle_hashes.emplace_back(coinbase_txid, coinbase_txid + 32);
            for (const auto &tx : tmpl.transactions) {
                auto h = hex_decode(tx.txid);
                std::reverse(h.begin(), h.end());
                merkle_hashes.push_back(std::move(h));
            }
            const std::vector<uint8_t> merkle_root = compute_merkle_root(std::move(merkle_hashes));

            std::cout << "Height: " << tmpl.height << "  bits: " << std::hex << tmpl.bits << std::dec << "\n";

            if (!tmpl.target_hex.empty()) {
                hex_target_to_bytes(tmpl.target_hex, target);
            } else {
                bits_to_target(tmpl.bits, target);
            }

            const auto header0 = build_header_bytes(tmpl, 0, merkle_root.data());

            // Rolling bound: GBT "maxtime" (consensus allows curtime + 2h at
            // most). Falls back to curtime + 7000 s if the field is missing.
            uint32_t gbt_maxtime = static_cast<uint32_t>(extract_json_int(tmpl_json, "maxtime"));
            if (gbt_maxtime <= tmpl.curtime) gbt_maxtime = tmpl.curtime + 7200;

            // Same work = everything except nTime identical. The rolled nTime
            // in prefix_saved may already be ahead of the template's curtime.
            const bool same_work = have_job &&
                std::memcmp(header0.data(), prefix_saved, 68) == 0 &&
                std::memcmp(header0.data() + 72, prefix_saved + 72, 4) == 0;

            if (same_work && ntime_current < ntime_max) {
                // The nonce space of the current header was fully swept last
                // round -- roll nTime forward instead of re-scanning it. The
                // midstate is unaffected (nTime lives in header block 2).
                ++ntime_current;
                for (int b = 0; b < 4; ++b)
                    prefix_saved[68 + b] = static_cast<uint8_t>((ntime_current >> (8 * b)) & 0xff);
                gpu.set_ntime(ntime_current);
                std::cout << "Template unchanged -- rolled nTime (+" << (ntime_current - base_curtime)
                          << " s) instead of rescanning\n";
            } else {
                std::memcpy(prefix_saved, header0.data(), 76);
                ntime_current = tmpl.curtime;
                base_curtime = tmpl.curtime;
                ntime_max = gbt_maxtime;
                height_current = tmpl.height;

                uint32_t midstate[8];
                sha256_midstate(prefix_saved, midstate);
                gpu.set_job(midstate, prefix_saved, target);

                if (cpu_threads > 0) {
                    CpuJob cj{};
                    std::memcpy(cj.midstate, midstate, sizeof(cj.midstate));
                    std::memcpy(cj.prefix, prefix_saved, 76);
                    std::memcpy(cj.target_msb, target, 32);
                    cj.ntime_max = ntime_max;
                    if (!have_job) {
                        cpu_pool.start(cpu_threads, gpu_chunks, cj);
                        std::cout << "CPU workers started\n";
                    } else {
                        cpu_pool.set_job(cj);
                    }
                }
                have_job = true;
            }

            bool found = false;
            uint32_t nonce = 0;
            uint64_t sweep_hashes = 0;
            const auto sweep_start = std::chrono::steady_clock::now();
            for (uint32_t span_idx = 0; span_idx < gpu_chunks; ++span_idx) {
                if (gpu.scan_chunk(span_idx << 24, GpuResult::NONCE_SPAN)) {
                    nonce = gpu.host_ctrl[1];
                    found = true;
                    break;
                }
                sweep_hashes += gpu.consume_hashes();

                // CPU finds are polled between GPU chunks (~10 ms cadence);
                // a verified one ends the sweep -- its block changes the tip,
                // making the rest of the sweep stale.
                if (cpu_threads > 0) {
                    uint8_t cpu_header[80];
                    if (cpu_pool.poll_find(cpu_header)) {
                        submit_header(tmpl, cpu_header, coinbase_tx, "CPU");
                        break;
                    }
                }
            }
            hash_total.fetch_add(sweep_hashes);
            const uint64_t cpu_hashes = cpu_threads > 0 ? cpu_pool.take_hashes() : 0;
            const double sweep_secs =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - sweep_start).count();
            const double gpu_ghps = static_cast<double>(sweep_hashes) / 1e9 / sweep_secs;
            const double cpu_ghps = static_cast<double>(cpu_hashes) / 1e9 / sweep_secs;

            if (found) {
                std::cout << "FOUND nonce=" << nonce << " after " << sweep_secs << " s\n";
                uint8_t header80[80];
                std::memcpy(header80, prefix_saved, 76); // carries the rolled nTime
                header80[76] = nonce & 0xff;
                header80[77] = (nonce >> 8) & 0xff;
                header80[78] = (nonce >> 16) & 0xff;
                header80[79] = (nonce >> 24) & 0xff;
                submit_header(tmpl, header80, coinbase_tx, "GPU");
            } else {
                std::cout << "Rate: " << std::fixed << std::setprecision(2)
                          << (gpu_ghps + cpu_ghps) << " GH/s (GPU " << gpu_ghps << " + CPU "
                          << cpu_ghps << ")  height " << height_current
                          << "  ntime +" << (ntime_current - base_curtime) << "s\n";
                std::cout.unsetf(std::ios::fixed);
            }
        } catch (const std::exception &e) {
            std::cerr << "Error: " << e.what() << "\n";
            std::this_thread::sleep_for(std::chrono::seconds(5));
        }

        if (!cfg.continuous) break;
        std::this_thread::sleep_for(std::chrono::seconds(1));
    } while (true);

    cpu_pool.stop();
    curl_global_cleanup();
#if defined(_WIN32)
    WSACleanup();
#endif
    return 0;
}