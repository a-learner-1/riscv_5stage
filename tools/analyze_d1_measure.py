#!/usr/bin/env python3
"""D1 analyzer: explicit G4 latest-START amendment; all other ledgers retained."""
from __future__ import annotations
from pathlib import Path
import sys


def read_kv(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line in ("key,value", "key,count"):
            continue
        if "," not in line:
            raise ValueError(f"malformed CSV row in {path.name}: {line!r}")
        key, val = line.split(",", 1)
        if key in result:
            raise ValueError(f"duplicate CSV field {key!r} in {path.name}")
        result[key] = val.strip()
    return result


def number(data: dict[str,str], name: str) -> int:
    if name not in data:
        raise ValueError(f"missing required CSV field {name}")
    try:
        val = int(data[name])
    except ValueError as exc:
        raise ValueError(f"non-integer field {name}={data[name]!r}") from exc
    if val < 0:
        raise ValueError(f"negative counter {name}={val}")
    return val


def rate(num: int, den: int) -> str:
    return f"{num / den * 100:.2f}%" if den else "n/a"


def analyze_one(path: Path) -> dict[str,float]:
    bucket_path = path.with_name(path.name.replace("_window.csv", "_buckets.csv"))
    if not bucket_path.is_file():
        raise FileNotFoundError(bucket_path)
    w, b = read_kv(path), read_kv(bucket_path)
    profile = w.get("profile", "")
    stem = path.name[len("d1_measure_"):-len("_window.csv")]
    if profile.replace("-", "_") != stem.replace("-", "_"):
        raise ValueError(f"profile mismatch filename={stem!r} contents={profile!r}")
    cap = number(w, "m1_cap")
    limit = number(w, "m1_limit")
    if cap < limit or cap != 40 or limit != 14:
        raise ValueError(f"unexpected measurement configuration cap={cap} limit={limit}")
    cycles = number(w,"window_cycles")
    stores = number(w,"m1_stores_window")
    if not cycles or not stores:
        raise ValueError("empty M1 measurement")
    hist = [number(b, f"m1_gap_{i}") for i in range(cap+1)]
    if sum(hist) != stores:
        raise ValueError(f"M1 bucket ledger {sum(hist)} != stores {stores}")
    cap_cens = number(w,"m1_censored_cap")
    win_cens = number(w,"m1_truncated_window")
    if cap_cens > hist[cap] or win_cens > 1 or (cap_cens+win_cens)>stores:
        raise ValueError("invalid right-censoring event counts")
    lower = number(w,"m1_residual_sum")
    extra = number(w,"m1_residual_trunc_sum")
    upper = number(w,"m1_residual_upper_sum")
    if lower+extra != upper:
        raise ValueError("M1 residual bounds do not close")
    if extra > win_cens * limit:
        raise ValueError("window-censored residual upper bound impossible")
    gap_sum = number(w,"m1_gap_sum")
    if gap_sum != sum(i * hist[i] for i in range(cap+1)):
        raise ValueError("M1 gap_sum differs from capped histogram")
    # G4 amended for these fixed one-iteration firmware images only.
    # Do not erase or relabel the portable_init ID probe's physical START.
    if (number(w,"start_triggers") != 2 or
            number(w,"selected_start_triggers") != 1 or
            number(w,"epoch") != 2 or number(w,"stop_triggers") != 1 or
            number(w,"crossings") != 0):
        raise ValueError("invalid revised G4 lifecycle: require raw START=2, selected START=1, epoch=2, STOP=1, crossings=0")
    if number(w,"stop_t")-number(w,"start_t")!=cycles:
        raise ValueError("window timestamps do not match cycles")
    resolved = number(w,"e_resolved")
    frozen_resolved=number(w,"frozen_resolved")
    direction=number(w,"measured_direction_error")
    frozen_direction=number(w,"frozen_direction_error")
    if not resolved or resolved!=frozen_resolved or direction!=frozen_direction:
        raise ValueError("M2 resolved/direction-error frozen reconciliation failed")
    miss=number(b,"e_miss_taken")
    wrong_taken=number(b,"e_hit_wrong_taken")
    wrong_nt=number(b,"e_hit_wrong_nt")
    hit=number(w,"e_hit")
    relearn=number(b,"e_relearn_all")
    nonjal=number(b,"e_relearn_nojal")
    if miss+wrong_taken+wrong_nt != direction:
        raise ValueError("M2 direction error categories do not close")
    if hit>resolved or relearn>resolved or nonjal>relearn or direction>resolved:
        raise ValueError("M2 event count out of range")
    print(f"\n=== {profile} ===")
    print("G4 REVISED PASS: raw START=2, selected START=1, epoch=2, STOP=1, crossings=0; latest START bank")
    print(f"window: cycles={cycles:,} stores={stores:,} capped_gap_mean_lower_bound={gap_sum/stores:.2f}")
    print(f"M1 cap={cap} capped_at_cap={cap_cens} window_censored={win_cens}")
    print(f"M1 residual LOWER={lower:,} UPPER={upper:,} ({rate(lower, cycles)}..{rate(upper,cycles)} of window)")
    print(f"M1 queue heuristic={number(w,'queue_residual_sum'):,} clamps={number(w,'queue_projection_clamps'):,}")
    print(f"M1 baseline frozen_write_wait={number(w,'frozen_data_write_wait'):,}")
    print("M1 S histogram (bucket CAP combines exact CAP and CAP-censored data):")
    for lo, hi in ((0,1),(1,2),(2,4),(4,7),(7,10),(10,14),(14,18),
                   (18,24),(24,32),(32,40),(40,41)):
        total=sum(hist[lo:hi])
        name=f"S>={cap}" if lo==cap else f"S={lo}-{hi-1}"
        print(f"   {name:<12} {total:>8,} {rate(total,stores)}")
    print(f"M2 resolved={resolved:,} frozen_resolved={frozen_resolved:,}  PASS")
    print(f"M2 direrr={direction:,} frozen_direrr={frozen_direction:,} PASS  ({rate(direction,resolved)})")
    print(f"M2 miss={miss:,} hit_wrong_NT={wrong_taken:,} hit_wrong_T={wrong_nt:,}")
    print(f"M2 relearn_all={relearn:,} ({rate(relearn,resolved)}) relearn_nonjal={nonjal:,}")
    print(f"M2 JALR-only resolved count={number(w,'e_jalr_unpredictable'):,} (not independently frozen)")
    print("D1 PROFILE PASS")
    return {"miss_frac":miss / direction if direction else 0.,
            "relearn_frac":relearn / resolved,
            "q_residual":number(w,'queue_residual_sum') / cycles}


def main() -> int:
    build=Path("build")
    expected={"smoke", "smoke_validation"}
    paths=list(build.glob("d1_measure_*_window.csv"))
    selected={}
    for path in paths:
        key=path.name[len("d1_measure_"):-len("_window.csv")].replace("-", "_")
        if key in expected:
            if key in selected:
                raise ValueError(f"ambiguous duplicated output profile: {key}")
            selected[key]=path
    if set(selected)!=expected:
        raise ValueError(f"missing required profiles: {sorted(expected-set(selected))}")
    results={name:analyze_one(selected[name]) for name in sorted(expected)}
    print("\nD1 DECISION -- measurements and heuristic projections only")
    for name, r in results.items():
        print(f"{name}: direction-miss-share={rate(round(r['miss_frac']*100000),100000)}, "
              f"relearn-share={rate(round(r['relearn_frac']*100000),100000)}, "
              f"queue-projection={r['q_residual']*100:.2f}%")
    print("D1 ANALYZER PASS: exactly two required profiles and every ledger verified")
    return 0


if __name__=="__main__":
    try:
        sys.exit(main())
    except (OSError,KeyError,ValueError) as exc:
        print(f"D1 ANALYZER ERROR: {exc}",file=sys.stderr)
        sys.exit(4)
