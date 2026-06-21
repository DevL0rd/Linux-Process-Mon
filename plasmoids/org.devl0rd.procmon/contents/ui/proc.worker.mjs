/*
 * Off-thread data pipeline for Process Monitor. Owns JSON.parse, the per-PID
 * history ring buffers, and the tree-walk that flattens to the visible row list
 * -- so the GUI thread only has to reconcile the ListModel. State (procs +
 * history) persists across messages, so a collapse/expand/sort/search re-walk
 * needs no re-parse.
 *
 *   In:  { text: <json string|null>, state: {...UI state...} }
 *   Out: { desired:[{pid,depth,hasChildren,expanded}], procByPid, sortHistByPid,
 *          memTotal, vramTotal }
 */
var procs = []
var byPid = {}
var childrenOf = {}
var hist = {}              // pid -> { metric: ring }
var memTotal = 0
var vramTotal = 0

function ringMake(cap) { return { buf: new Array(cap), head: 0, len: 0, cap: cap } }
function ringPush(r, v) { r.buf[r.head] = v; r.head = (r.head + 1) % r.cap; if (r.len < r.cap) r.len++ }
function ringValues(r) {
    var n = r.len, out = new Array(n), start = (r.head - n + r.cap) % r.cap
    for (var i = 0; i < n; i++) out[i] = r.buf[(start + i) % r.cap]
    return out
}
function colVal(p, key, noagg, aggregate) {
    if (noagg) return p[key] || 0
    if (aggregate) { var a = p["a" + key]; return a === undefined ? (p[key] || 0) : a }
    return p[key] || 0
}
function passes(p, showKernel) { return p && (showKernel || !p.kernel) }
function isHidden(p, hideSystemd) { return hideSystemd && (p.pid === 1 || p.name === "systemd") }

function build(s) {
    var sc = s.sortColumn, agg = s.aggregate, sk = s.showKernel, hs = s.hideSystemd, noagg = s.sortNoagg
    function sortVal(p) { return sc === "name" ? (p.name || "").toLowerCase() : colVal(p, sc, noagg, agg) }
    function cmp(a, b) {
        var av = sortVal(a), bv = sortVal(b)
        var r = av < bv ? -1 : (av > bv ? 1 : 0)
        return s.sortDescending ? -r : r
    }
    function histArr(pid) {
        if (sc === "name" || sc === "pid") return []
        var h = hist[pid]
        return (h && h[sc]) ? ringValues(h[sc]) : []
    }
    var desired = [], pbp = {}, shb = {}
    function emit(p, depth, has, exp) {
        pbp[p.pid] = p
        shb[p.pid] = histArr(p.pid)
        desired.push({ pid: p.pid, depth: depth, hasChildren: has, expanded: exp })
    }
    if (s.searchText !== "") {
        var ql = s.searchText.toLowerCase()
        var mm = procs.filter(function(p) { return passes(p, sk) && (p.name || "").toLowerCase().indexOf(ql) >= 0 })
        mm.sort(cmp)
        for (var i = 0; i < mm.length; i++) emit(mm[i], 0, false, false)
    } else {
        var rl = procs.filter(function(p) {
            if (!passes(p, sk) || isHidden(p, hs)) return false
            var par = byPid[p.ppid]
            return par === undefined || isHidden(par, hs) || !passes(par, sk)
        })
        rl.sort(cmp)
        var expanded = s.expanded || {}
        var walk = function(p, depth) {
            var cids = childrenOf[p.pid], kids = []
            if (cids) for (var c = 0; c < cids.length; c++) {
                var kk = byPid[cids[c]]
                if (kk && passes(kk, sk) && !isHidden(kk, hs)) kids.push(kk)
            }
            var has = kids.length > 0, exp = expanded[p.pid] === true
            emit(p, depth, has, exp)
            if (has && exp) { kids.sort(cmp); for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1) }
        }
        for (var j = 0; j < rl.length; j++) walk(rl[j], 0)
    }
    return { desired: desired, procByPid: pbp, sortHistByPid: shb, memTotal: memTotal, vramTotal: vramTotal }
}

WorkerScript.onMessage = function(msg) {
    var s = msg.state
    if (msg.text) {                                    // new snapshot -> parse + accumulate
        var d
        try { d = JSON.parse(msg.text) } catch (e) { return }
        var ps = d.procs || []
        memTotal = d.mem_total || 0
        vramTotal = d.vram_total || 0
        var keys = s.histKeys
        var fields = s.aggregate ? keys.map(function(k) { return "a" + k }) : keys
        var bp = {}, ch = {}, nh = {}
        for (var k = 0; k < ps.length; k++) {
            var pp = ps[k]
            bp[pp.pid] = pp
            ;(ch[pp.ppid] = ch[pp.ppid] || []).push(pp.pid)
            var hh = hist[pp.pid] || {}
            for (var m = 0; m < keys.length; m++) {
                var key = keys[m]
                var r = hh[key] || (hh[key] = ringMake(s.histLen))
                ringPush(r, pp[fields[m]] || 0)
            }
            nh[pp.pid] = hh
        }
        procs = ps; byPid = bp; childrenOf = ch; hist = nh
    }
    WorkerScript.sendMessage(build(s))                 // always re-walk with current UI state
}
