# EXPERT-ADVOSOR

Professional XPTicks EA implementation with production-grade controls for win-rate durability and longevity.

## Files
- `/home/runner/work/EXPERT-ADVOSOR/EXPERT-ADVOSOR/XPTicks_Professional_EA.mq5` — MQL5 EA scaffold implementing risk, filters, execution safeguards, and monitoring.
- `/home/runner/work/EXPERT-ADVOSOR/EXPERT-ADVOSOR/BACKTESTING_WORKFLOW.md` — baseline + anti-overfitting validation workflow.

## Implemented upgrades
1. Baseline workflow support documented (win rate, PF, DD, expectancy, streaks, duration across symbols/regimes).
2. Strict risk architecture:
   - Fixed risk-per-trade sizing
   - Daily and weekly drawdown guardrails
   - Max concurrent position controls
   - Spread/slippage gating
   - Volatility spike blocking
3. Signal quality separation:
   - Entry logic (EMA cross + RSI)
   - Regime filters (session, volatility, liquidity)
4. Adaptive position management:
   - ATR-based SL/TP
   - Break-even, trailing, partial close, time-based exits
5. Anti-overfitting workflow included:
   - Walk-forward, OOS, Monte Carlo, parameter stability rules
6. Portfolio controls:
   - Same-currency exposure cap for open portfolio
7. Execution safeguards:
   - Retry logic with slippage limits and broker stop-level normalization
8. Monitoring and auto-protection:
   - Periodic health logging
   - Consecutive-loss anomaly detection
   - Auto-disable on loss streak or drawdown breach

## Notes
- This is a professional scaffold designed for iterative tuning and validation.
- News-calendar filtering is environment/broker dependent and should be connected to your preferred event feed.
