# =========================================================
# 1. System Clock Definition (100 MHz -> 10ns period)
# =========================================================
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]

# =========================================================
# 2. ADC Radar Clock Definition (40 MHz -> 25ns period)
# =========================================================
# create_clock -period 25.000 -name adc_clk -waveform {0.000 12.500} [get_ports adc_clk]

# =========================================================
# 3. Clock Domain Crossing (CDC) Constraint
# =========================================================
# This tells Vivado that these two clocks are asynchronous.
# It prevents Vivado from trying to analyze timing paths THROUGH the ASYNC_FIFO.
# set_clock_groups -asynchronous -group [get_clocks sys_clk] -group [get_clocks adc_clk]