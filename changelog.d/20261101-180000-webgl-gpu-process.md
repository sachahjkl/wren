type: Changed

**A GPU process for WebGL**: wgpu, drivers and shader compilers run in a process of their own, started by the first context of the browser. A crash or a hang there costs contexts (`webglcontextlost`, and `webglcontextrestored` for a page that asked for it, from a new process), never the browser; a hung process is killed, not left behind; it ends with its parent; it runs with lowered rights, and nothing that crosses is believed (`webgl.gpu_hang_ms`, `webgl.gpu_max_restarts`, `webgl.gpu_restart_window_s`, `webgl.gpu_idle_exit_s`, `webgl.gpu_keep_rights`).
