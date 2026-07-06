"""
verify_stage2.py
=================
Stage 2 (Feature Extraction / CNN backbone) RTL vs Python verification.

Compares:
    feature_output.hex  (written by RTL TB, channel-first serial, 65536 lines)
    stage2_golden.hex  (from pt_to_hex.py, same order)

Shape: (128, 16, 32)  ->  128 channels x 512 pixels each = 65536 values

Produces:
    - overall correlation (amplitude / signed match)
    - per-channel correlation table (helps find WHICH channel/stage diverges)
    - plots of a few representative channels (best, worst, median)
"""

import os
import numpy as np
import matplotlib.pyplot as plt

# =========================================================
# Config
# =========================================================
C_OUT, H_OUT, W_OUT = 128, 16, 32
PIXELS_PER_CH = H_OUT * W_OUT          # 512
TOTAL = C_OUT * PIXELS_PER_CH          # 65536

RTL_FILE    = "D:\\GP\\accuracy_test\\Feature_output.hex"      # one hex value per line, signed Q8.8
GOLDEN_FILE = "D:\\GP\\accuracy_test\\stage2_golden.hex"      # one hex value per line, signed Q8.8

SCALE = 256.0  # Q8.8


# =========================================================
# Hex readers
# =========================================================
def read_hex_q88(filename):
    """Read a file with one 4-digit hex value per line -> float array (Q8.8 -> real)."""
    if not os.path.exists(filename):
        print(f"ERROR: file not found: {filename}")
        return None

    vals = []
    with open(filename, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                v = int(line, 16)
                if v >= 0x8000:
                    v -= 0x10000
                vals.append(v)
            except ValueError:
                pass

    return np.array(vals, dtype=np.int32)


# =========================================================
# Correlation helper (same style as Stage 1: normalized correlation %)
# =========================================================
def calculate_match(rtl_arr, py_arr):
    """Normalized correlation, returned as a percentage (0-100)."""
    if len(rtl_arr) < 2 or len(py_arr) < 2:
        return float("nan")

    r_range = np.max(rtl_arr) - np.min(rtl_arr)
    p_range = np.max(py_arr) - np.min(py_arr)

    if r_range < 1e-12 or p_range < 1e-12:
        # constant array(s) -> correlation undefined, treat as 100% if both ~equal
        if np.allclose(rtl_arr, py_arr, atol=1):
            return 100.0
        return 0.0

    r_n = (rtl_arr - np.min(rtl_arr)) / (r_range + 1e-12)
    p_n = (py_arr - np.min(py_arr)) / (p_range + 1e-12)

    corr = np.corrcoef(r_n, p_n)[0, 1]
    if np.isnan(corr):
        return 0.0
    return corr * 100.0


def mean_abs_error_q88(rtl_arr, py_arr):
    """Mean absolute error in Q8.8 LSBs and in real units."""
    diff = np.abs(rtl_arr.astype(np.float64) - py_arr.astype(np.float64))
    return diff.mean(), diff.mean() / SCALE


# =========================================================
# Main verification
# =========================================================
def verify_stage2():
    print("=" * 75)
    print("STAGE 2 VERIFICATION  (RTL vs Python golden)")
    print("=" * 75)

    rtl = read_hex_q88(RTL_FILE)
    py  = read_hex_q88(GOLDEN_FILE)

    if rtl is None or py is None:
        return

    min_len = min(len(rtl), len(py))
    if min_len != TOTAL:
        print(f"WARNING: expected {TOTAL} values, "
              f"got RTL={len(rtl)} golden={len(py)}, comparing first {min_len}")

    rtl = rtl[:min_len]
    py  = py[:min_len]

    # ---------------------------------------------------------
    # Overall stats
    # ---------------------------------------------------------
    overall_match = calculate_match(rtl.astype(np.float64), py.astype(np.float64))
    mae_lsb, mae_real = mean_abs_error_q88(rtl, py)

    print(f"\nTotal samples compared : {min_len:,}")
    print(f"Overall correlation    : {overall_match:.2f}%")
    print(f"Mean abs error         : {mae_lsb:.3f} LSB  ({mae_real:.5f} real units)")
    print(f"RTL    range (Q8.8)    : [{rtl.min()}, {rtl.max()}]"
          f"  -> real [{rtl.min()/SCALE:.4f}, {rtl.max()/SCALE:.4f}]")
    print(f"Golden range (Q8.8)    : [{py.min()}, {py.max()}]"
          f"  -> real [{py.min()/SCALE:.4f}, {py.max()/SCALE:.4f}]")

    # ---------------------------------------------------------
    # Per-channel correlation (128 channels x 512 pixels)
    # ---------------------------------------------------------
    n_full_ch = min_len // PIXELS_PER_CH
    print(f"\nPer-channel correlation ({n_full_ch} channels, "
          f"{PIXELS_PER_CH} pixels each):")
    print("-" * 75)

    ch_matches = []
    for ch in range(n_full_ch):
        s = ch * PIXELS_PER_CH
        e = s + PIXELS_PER_CH
        m = calculate_match(rtl[s:e].astype(np.float64), py[s:e].astype(np.float64))
        ch_matches.append(m)

    ch_matches = np.array(ch_matches)

    # Print summary stats + worst offenders
    print(f"  Mean channel match  : {np.nanmean(ch_matches):.2f}%")
    print(f"  Min  channel match  : {np.nanmin(ch_matches):.2f}%  "
          f"(channel {np.nanargmin(ch_matches)})")
    print(f"  Max  channel match  : {np.nanmax(ch_matches):.2f}%  "
          f"(channel {np.nanargmax(ch_matches)})")

    n_bad = np.sum(ch_matches < 90.0)
    n_ok  = np.sum(ch_matches >= 90.0)
    print(f"  Channels >= 90% match : {n_ok} / {n_full_ch}")
    print(f"  Channels <  90% match : {n_bad} / {n_full_ch}")

    # show worst 10 channels
    worst_idx = np.argsort(ch_matches)[:10]
    print("\n  Worst 10 channels:")
    for ch in worst_idx:
        print(f"    ch{ch:3d}: match={ch_matches[ch]:6.2f}%")

    # ---------------------------------------------------------
    # Plots
    # ---------------------------------------------------------
    plot_channel_summary(ch_matches)

    best_ch  = int(np.nanargmax(ch_matches))
    worst_ch = int(np.nanargmin(ch_matches))
    median_ch = int(np.argsort(ch_matches)[len(ch_matches) // 2])

    for ch, label in [(best_ch, "best"), (median_ch, "median"), (worst_ch, "worst")]:
        plot_channel(rtl, py, ch, ch_matches[ch], label)

    return overall_match, ch_matches


# =========================================================
# Plot helpers
# =========================================================
def plot_channel_summary(ch_matches):
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.bar(range(len(ch_matches)), ch_matches, color="#378ADD")
    ax.axhline(90, color="#E24B4A", linestyle="--", linewidth=1, label="90% threshold")
    ax.set_xlabel("Channel index")
    ax.set_ylabel("Correlation (%)")
    ax.set_title("Stage 2: per-channel correlation (RTL vs golden)")
    ax.set_ylim(0, 105)
    ax.legend()
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.show()


def plot_channel(rtl, py, ch, match_pct, label):
    s = ch * PIXELS_PER_CH
    e = s + PIXELS_PER_CH

    rtl_ch = rtl[s:e].astype(np.float64) / SCALE
    py_ch  = py[s:e].astype(np.float64) / SCALE

    rtl_2d = rtl_ch.reshape(H_OUT, W_OUT)
    py_2d  = py_ch.reshape(H_OUT, W_OUT)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4))
    fig.suptitle(f"Stage 2 channel {ch} ({label}, match={match_pct:.2f}%)",
                  fontsize=13, fontweight="bold")

    vmin = min(rtl_ch.min(), py_ch.min())
    vmax = max(rtl_ch.max(), py_ch.max())

    im0 = axes[0].imshow(py_2d, vmin=vmin, vmax=vmax, cmap="viridis")
    axes[0].set_title("Python golden")
    plt.colorbar(im0, ax=axes[0])

    im1 = axes[1].imshow(rtl_2d, vmin=vmin, vmax=vmax, cmap="viridis")
    axes[1].set_title("RTL")
    plt.colorbar(im1, ax=axes[1])

    diff = rtl_2d - py_2d
    im2 = axes[2].imshow(diff, cmap="coolwarm")
    axes[2].set_title(f"Diff (max abs={np.abs(diff).max():.4f})")
    plt.colorbar(im2, ax=axes[2])

    plt.tight_layout()
    plt.show()


# =========================================================
# Entry point
# =========================================================
if __name__ == "__main__":
    verify_stage2()