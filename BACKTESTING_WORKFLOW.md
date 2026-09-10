# XPTicks EA Validation Workflow

## 1) Baseline performance
Run an unchanged baseline pass before any optimization and record:
- Win rate
- Profit factor
- Max drawdown (absolute and relative)
- Expectancy per trade
- Longest win/loss streak
- Average trade duration

Minimum baseline matrix:
- Symbols: at least 5 instruments from different behavior classes
- Regimes: trend, range, high-volatility, low-volatility segments
- Time slices: at least 3 non-overlapping date windows

## 2) Walk-forward process
- Split data into repeated train/test windows.
- Optimize only on training windows.
- Freeze parameters and evaluate on next forward test window.
- Promote only parameter sets with consistent forward equity behavior.

## 3) Out-of-sample validation
- Keep a final untouched holdout interval.
- Run a single pass on the holdout after strategy lock.
- Reject any candidate with major metric collapse vs walk-forward medians.

## 4) Monte Carlo robustness
For accepted candidates, randomize execution assumptions:
- Spread expansion
- Slippage perturbation
- Missed entries/exits
- Trade sequence reshuffling

Accept only if risk limits remain inside policy under stress.

## 5) Parameter stability screening
- Sweep parameters around the chosen point.
- Prefer broad stability plateaus over narrow peaks.
- Reject fragile settings with sharp performance cliffs.

## 6) Production gates
Promote to live only when all conditions pass:
- Daily/weekly drawdown policy respected
- Stable expectancy across symbols/regimes
- Monte Carlo stress still profitable or acceptable by policy
- No recurring execution-failure pattern in logs
