-- conf/flv_close.lua - log-phase hook for /live: decrement the concurrent
-- HTTP-FLV viewer count that conf/flv_auth.lua bumped in the access phase.
-- Runs exactly once per request when the FLV body ends (viewer disconnect or
-- error), so the shared-dict counter tracks live viewers across all workers.
--
-- Only a request that actually bumped the counter may decrement it. The log
-- phase runs for every finalized request, including the ones the access phase
-- rejected with 400/403 -- those never incremented. Decrementing on their
-- behalf would steal a live viewer's slot, i.e. anyone could zero a stream's
-- count by replaying a bad-signature /live request. flv_auth.lua stashes the
-- key in ngx.ctx on the incrementing path; ngx.ctx hangs off r->pool and
-- outlives the log phase, so it is the right carrier for access -> log state.
--
-- The decrement is a bare incr() rather than get()+incr(): the read is not
-- atomic with the write, so two log phases racing on the same key could both
-- observe cur == 1 and both subtract.
local key = ngx.ctx.flvcnt_key
if key then
    -- shared-dict API: no decr(), incr() accepts negatives
    ngx.shared.rtc_stats:incr(key, -1)
end
