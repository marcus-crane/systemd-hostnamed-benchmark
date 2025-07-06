#!/usr/bin/env python3

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import sys
import argparse
from pathlib import Path

def analyze_systemd_performance(csv_file):
    try:
        df = pd.read_csv(csv_file)
        print(f"Loaded {len(df)} individual iterations from {csv_file}")
    except Exception as e:
        print(f"Error reading CSV file: {e}")
        return

    df['startup_time_s'] = df['startup_time_ms'] / 1000

    grouped = df.groupby('mount_count')

    print(f"\nComprehensive Statistics by Mount Count:")
    print("=" * 100)

    summary_stats = []

    for mount_count, group in grouped:
        startup_times = group['startup_time_s']
        success_count = (group['success'] == True).sum()
        total_iterations = len(group)
        success_rate = (success_count / total_iterations) * 100

        stats = {
            'mount_count': int(mount_count),
            'iterations': total_iterations,
            'successes': success_count,
            'failures': total_iterations - success_count,
            'success_rate': success_rate,
            'min_time': startup_times.min(),
            'max_time': startup_times.max(),
            'mean_time': startup_times.mean(),
            'median_time': startup_times.median(),
            'std_time': startup_times.std() if len(startup_times) > 1 else 0.0,
            'q25_time': startup_times.quantile(0.25),
            'q75_time': startup_times.quantile(0.75),
        }

        summary_stats.append(stats)

        print(f"\nMount Count: {stats['mount_count']:4d} | Iterations: {stats['iterations']:2d} | Success Rate: {stats['success_rate']:5.1f}%")
        print(f"  Times (s): Min={stats['min_time']:6.3f} | Q25={stats['q25_time']:6.3f} | Median={stats['median_time']:6.3f} | Mean={stats['mean_time']:6.3f} | Q75={stats['q75_time']:6.3f} | Max={stats['max_time']:6.3f}")

        if stats['iterations'] > 1:
            print(f"  Variability: StdDev={stats['std_time']:6.3f}s | Range={stats['max_time']-stats['min_time']:6.3f}s")
        else:
            print(f"  Variability: StdDev=  N/A (single value) | Range={stats['max_time']-stats['min_time']:6.3f}s")

        failures = group[group['success'] == False]
        if len(failures) > 0:
            print(f"  Failures: {', '.join([f'iter{int(row.iteration)}({row.startup_time_s:.1f}s)' for _, row in failures.iterrows()])}")

    summary_df = pd.DataFrame(summary_stats)

    print(f"\n\nCritical Analysis:")
    print("=" * 60)

    baseline = summary_df[summary_df['mount_count'] == 0]
    if not baseline.empty:
        baseline_median = float(baseline['median_time'].iloc[0])
        print(f"Baseline median startup time: {baseline_median:.3f}s")

        print(f"\nPerformance Degradation Points:")
        for multiplier, label in [(2, "2x"), (5, "5x"), (10, "10x"), (50, "50x"), (100, "100x")]:
            threshold = baseline_median * multiplier
            degraded = summary_df[summary_df['median_time'] > threshold]
            if not degraded.empty:
                first_degraded = degraded.iloc[0]
                mount_count = int(first_degraded['mount_count'])
                median_time = float(first_degraded['median_time'])
                print(f"  {label:3s} slower: {mount_count:4d} mounts ({median_time:.3f}s median)")

    print(f"\nFailure Analysis:")
    failures = summary_df[summary_df['success_rate'] < 100]
    if not failures.empty:
        first_failure = failures.iloc[0]
        mount_count = int(first_failure['mount_count'])
        success_rate = float(first_failure['success_rate'])
        print(f"  First partial failures: {mount_count:4d} mounts ({success_rate:.1f}% success)")

        complete_failures = summary_df[summary_df['success_rate'] == 0]
        if not complete_failures.empty:
            first_complete = complete_failures.iloc[0]
            mount_count = int(first_complete['mount_count'])
            print(f"  Complete failure: {mount_count:4d} mounts (0% success)")
    else:
        print("  No failures detected in dataset")

    timeouts = summary_df[summary_df['max_time'] >= 90]
    if not timeouts.empty:
        first_timeout = timeouts.iloc[0]
        mount_count = int(first_timeout['mount_count'])
        print(f"  First systemd timeout (≥90s): {mount_count:4d} mounts")
    else:
        print("  No systemd timeouts detected")

    print(f"\nVariability Analysis:")
    high_variance = summary_df[summary_df['std_time'] > 5]
    if not high_variance.empty:
        mount_counts = [int(x) for x in high_variance['mount_count']]
        print(f"  High variability (>5s std dev) at mount counts: {mount_counts}")
    else:
        print("  No high variability detected (need multiple iterations per mount count)")

    create_comprehensive_plots(summary_df, csv_file)

    output_file = Path(csv_file).stem + '_summary_statistics.csv'
    summary_df.to_csv(output_file, index=False)
    print(f"\nSummary statistics saved to: {output_file}")

    return summary_df

def create_comprehensive_plots(summary_df, csv_file):

    fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(16, 12))
    fig.suptitle('systemd-hostnamed Performance Analysis', 
                 fontsize=16, fontweight='bold')

    if summary_df['std_time'].max() > 0:
        ax1.errorbar(summary_df['mount_count'], summary_df['median_time'], 
                    yerr=[summary_df['median_time'] - summary_df['q25_time'], 
                          summary_df['q75_time'] - summary_df['median_time']], 
                    fmt='o-', linewidth=2, markersize=8, capsize=5,
                    color='red', markerfacecolor='darkred', ecolor='red', alpha=0.7)
    else:
        ax1.plot(summary_df['mount_count'], summary_df['median_time'], 'o-', 
                linewidth=2, markersize=8, color='red', markerfacecolor='darkred')

    ax1.set_xlabel('Number of Mounts', fontweight='bold')
    ax1.set_ylabel('Startup Time (seconds)', fontweight='bold')
    ax1.set_title('Median Startup Time')
    ax1.grid(True, alpha=0.3)
    ax1.axhline(y=90, color='red', linestyle='--', alpha=0.8, label='systemd timeout (90s)')
    ax1.legend()

    max_time = summary_df['median_time'].max()
    if max_time > 60:
        y_ticks = list(range(0, int(max_time) + 30, 30))
        ax1.set_yticks(y_ticks)
        ax1.set_yticklabels([f'{t}s' for t in y_ticks])
    else:
        y_ticks = list(range(0, int(max_time) + 10, 10))
        ax1.set_yticks(y_ticks)
        ax1.set_yticklabels([f'{t}s' for t in y_ticks])

    ax2.plot(summary_df['mount_count'], summary_df['success_rate'], 'o-', 
             linewidth=3, markersize=8, color='green', markerfacecolor='darkgreen')
    ax2.set_xlabel('Number of Mounts', fontweight='bold')
    ax2.set_ylabel('Success Rate (%)', fontweight='bold')
    ax2.set_title('Service Startup Success Rate')
    ax2.grid(True, alpha=0.3)
    ax2.set_ylim(0, 105)
    ax2.axhline(y=100, color='gray', linestyle='--', alpha=0.5)

    has_variability = summary_df['std_time'].max() > 0

    if has_variability:
        ax3.fill_between(summary_df['mount_count'], summary_df['min_time'], summary_df['max_time'], 
                         alpha=0.3, color='blue', label='Min-Max Range')
        ax3.plot(summary_df['mount_count'], summary_df['mean_time'], 'o-', 
                 linewidth=2, markersize=6, color='blue', label='Mean')
        ax3.set_xlabel('Number of Mounts', fontweight='bold')
        ax3.set_ylabel('Startup Time (seconds)', fontweight='bold')
        ax3.set_title('Startup Time Variability')
        ax3.grid(True, alpha=0.3)
        ax3.legend()

        max_time_3 = summary_df['max_time'].max()
        if max_time_3 > 60:
            y_ticks_3 = list(range(0, int(max_time_3) + 30, 30))
            ax3.set_yticks(y_ticks_3)
            ax3.set_yticklabels([f'{t}s' for t in y_ticks_3])
    else:
        ax3.text(0.5, 0.5, 'Multiple iterations per\nmount count needed\nfor variability analysis', 
                ha='center', va='center', transform=ax3.transAxes, fontsize=12,
                bbox=dict(boxstyle="round,pad=0.5", facecolor='lightgray', alpha=0.8))
        ax3.set_title('Startup Time Variability')
        ax3.set_xlabel('Number of Mounts', fontweight='bold')
        ax3.set_ylabel('Startup Time (seconds)', fontweight='bold')
        ax3.grid(True, alpha=0.3)

    if summary_df['std_time'].max() > 0:
        ax4.plot(summary_df['mount_count'], summary_df['std_time'], 'o-', 
                 linewidth=2, markersize=8, color='purple', markerfacecolor='darkviolet')
        ax4.set_ylabel('Standard Deviation (seconds)', fontweight='bold')
        ax4.set_title('Performance Consistency (Lower = More Consistent)')
    else:
        ax4.text(0.5, 0.5, 'Multiple iterations per\nmount count needed\nfor variability analysis', 
                ha='center', va='center', transform=ax4.transAxes, fontsize=12,
                bbox=dict(boxstyle="round,pad=0.5", facecolor='lightgray', alpha=0.8))
        ax4.set_title('Performance Consistency Analysis')

    ax4.set_xlabel('Number of Mounts', fontweight='bold')
    ax4.grid(True, alpha=0.3)

    plt.tight_layout()

    output_file = Path(csv_file).stem + '_comprehensive_analysis.png'
    plt.savefig(output_file, dpi=300, bbox_inches='tight', facecolor='white')
    print(f"Comprehensive analysis plot saved as: {output_file}")

    plt.show()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Analyze systemd-hostnamed performance data')
    parser.add_argument('csv_file', help='Path to the raw CSV results file')

    args = parser.parse_args()

    if not Path(args.csv_file).exists():
        print(f"Error: File {args.csv_file} not found")
        sys.exit(1)

    analyze_systemd_performance(args.csv_file)
