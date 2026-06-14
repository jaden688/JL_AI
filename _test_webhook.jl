# Sanity harness for the Stripe webhook helpers.
# Loads a2a_billing.jl in isolation, fabricates a Stripe-style signed request,
# and asserts signature verification + license key generation behave correctly.
# Run:  julia --project=. _test_webhook.jl

using Pkg
Pkg.activate(".")

using HTTP, JSON, SQLite, DataFrames, Dates, UUIDs, SHA, Random, Base64

# a2a_billing.jl references these but they're normally brought in via a2a_server.jl.
# Include the bare minimum for the helpers under test.
include("a2a_billing.jl")

println("== Test 1: signature verification (happy path) ==")
secret  = "whsec_test_deadbeef"
payload = """{"id":"evt_1","type":"checkout.session.completed","data":{"object":{"id":"cs_test_123","customer":"cus_x","subscription":"sub_y","customer_details":{"email":"a@b.com"},"payment_status":"paid","mode":"subscription"}}}"""
t       = round(Int, time())
signed  = string(t, ".", payload)
sig     = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits(secret)), Vector{UInt8}(codeunits(signed))))
header  = "t=$t,v1=$sig"
println("  header = ", header)
@assert _a2a_verify_stripe_signature(payload, header, secret) "expected verify to pass for fresh signature"
println("  PASS")

println("== Test 2: signature fails on tampered payload ==")
bad_payload = replace(payload, "cus_x" => "cus_ATTACKER")
@assert !_a2a_verify_stripe_signature(bad_payload, header, secret) "tampered payload must fail"
println("  PASS")

println("== Test 3: signature fails on wrong secret ==")
@assert !_a2a_verify_stripe_signature(payload, header, "whsec_wrong") "wrong secret must fail"
println("  PASS")

println("== Test 4: signature fails on stale timestamp ==")
stale_t      = round(Int, time()) - 3600  # 1 hour old
stale_signed = string(stale_t, ".", payload)
stale_sig    = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits(secret)), Vector{UInt8}(codeunits(stale_signed))))
stale_hdr    = "t=$stale_t,v1=$stale_sig"
@assert !_a2a_verify_stripe_signature(payload, stale_hdr, secret; tolerance_s=300) "stale timestamp must fail"
println("  PASS")

println("== Test 5: empty secret fails closed ==")
@assert !_a2a_verify_stripe_signature(payload, header, "") "empty secret must fail"
println("  PASS")

println("== Test 6: malformed header fails ==")
@assert !_a2a_verify_stripe_signature(payload, "notastripeheader", secret) "malformed header must fail"
println("  PASS")

println("== Test 7: multi-signature header (rolled secrets) ==")
multi_hdr = "t=$t,v1=0000deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdead,v1=$sig"
@assert _a2a_verify_stripe_signature(payload, multi_hdr, secret) "multi-v1 header with one valid sig must pass"
println("  PASS")

println("== Test 8: license key format ==")
k = _a2a_generate_license_key()
println("  key = ", k)
@assert startswith(k, "sb_live_") "prefix wrong"
@assert length(k) == length("sb_live_") + 32 "length wrong: $(length(k))"
@assert all(c -> c in "0123456789abcdef", k[length("sb_live_")+1:end]) "non-hex chars"
# And two calls produce different keys:
k2 = _a2a_generate_license_key()
@assert k != k2 "keys must be random"
println("  PASS")

println("== Test 9: end-to-end checkout.session.completed applies cleanly ==")
tmpdb = SQLite.DB(tempname())
_billing_init_db!(tmpdb)
session_obj = Dict{String,Any}(
    "id"                => "cs_live_TESTSESSION",
    "customer"          => "cus_TEST",
    "subscription"      => "sub_TEST",
    "customer_details"  => Dict{String,Any}("email" => "buyer@example.com"),
    "payment_status"    => "paid",
    "mode"              => "subscription",
)
result = _a2a_apply_checkout_completed!(tmpdb, session_obj)
println("  result = ", result)
@assert !get(result, "reused", true) "first call must mint new key"
@assert startswith(result["api_key"], "sb_live_") "minted key must be sparkbyte-formatted"

# Idempotent retry must return SAME key
result2 = _a2a_apply_checkout_completed!(tmpdb, session_obj)
@assert result2["api_key"] == result["api_key"] "idempotent replay must reuse key"
@assert get(result2, "reused", false) "replay must flag reused=true"
println("  idempotent replay matches: PASS")

# Lookup by session id works
acct = _a2a_find_account_by_session(tmpdb, "cs_live_TESTSESSION")
@assert acct !== nothing "should find account by session id"
@assert acct["api_key"] == result["api_key"] "session lookup returns correct key"
@assert acct["billing_email"] == "buyer@example.com" "email stored"
@assert acct["subscription_status"] == "active" "status active"
println("  session lookup: PASS")

println("== Test 10: subscription.updated lifecycle ==")
sub_obj_canceled = Dict{String,Any}(
    "id"        => "sub_TEST",
    "customer"  => "cus_TEST",
    "status"    => "canceled",
)
r = _a2a_apply_subscription_updated!(tmpdb, sub_obj_canceled)
@assert r["status"] == "canceled" "mapped status canceled"
acct_after = _a2a_get_account(tmpdb, result["api_key"])
@assert acct_after["subscription_status"] == "canceled" "status persisted to db"
println("  canceled mapping: PASS")

sub_obj_past_due = Dict{String,Any}(
    "id"        => "sub_TEST",
    "customer"  => "cus_TEST",
    "status"    => "past_due",
)
r2 = _a2a_apply_subscription_updated!(tmpdb, sub_obj_past_due)
@assert r2["status"] == "grace" "past_due mapped to grace"
println("  grace mapping: PASS")

println()
println("ALL WEBHOOK TESTS PASSED ✓")
