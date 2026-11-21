# 源同步屏口的时序预算，采样沿比推出沿晚半个像素周期。
create_generated_clock -name an970_sample -source [get_pins u_clock/u_panel_clock/C] -divide_by 1 -invert [get_ports lcd_dclk]
set lcd_data [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hs lcd_vs lcd_de}]
set_output_delay -clock an970_sample -max 8.0 $lcd_data
set_output_delay -clock an970_sample -min -5.0 $lcd_data
