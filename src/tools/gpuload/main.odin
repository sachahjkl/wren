package gpuload

// A background GPU load that keeps the graphics clock high (the driver lowers it when the GPU is mostly idle, which
// inflates every GPU duration measured at low load: tools\gpu_diag.ps1 -Load). Compute dispatches of about
// <busy> ms each, run at the lowest GPU thread priority so the browser's frames preempt them, then <idle> ms of rest.
//   gpuload.exe [seconds=20] [idle_ms=0] [groups=2048]

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"

SRC :: `
RWStructuredBuffer<float> o : register(u0);
[numthreads(256, 1, 1)] void cs(uint3 id : SV_DispatchThreadID) {
	float a = id.x * 0.001, b = 1.0001;
	[loop] for (int i = 0; i < 1024; i++) { a = a * b + 0.5; b = b * 0.9999 + a * 1e-9; }
	o[id.x & 255] = a + b;
}
`

main :: proc() {
	seconds, idle_ms, groups := 20, 0, 2048
	if len(os.args) > 1 { seconds, _ = strconv.parse_int(os.args[1]) }
	if len(os.args) > 2 { idle_ms, _ = strconv.parse_int(os.args[2]) }
	if len(os.args) > 3 { groups, _ = strconv.parse_int(os.args[3]) }

	fl := [?]d3d11.FEATURE_LEVEL{._11_0}
	dev: ^d3d11.IDevice
	ctx: ^d3d11.IDeviceContext
	if win.FAILED(d3d11.CreateDevice(nil, .HARDWARE, nil, {}, &fl[0], 1, d3d11.SDK_VERSION, &dev, nil, &ctx)) {
		fmt.eprintln("gpuload: no device")
		os.exit(1)
	}
	dxgi_dev: ^dxgi.IDevice
	if win.SUCCEEDED(dev->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_dev))) {
		dxgi_dev->SetGPUThreadPriority(-7)
		dxgi_dev->Release()
	}
	blob, errors: ^d3d11.IBlob
	src := SRC
	if win.FAILED(d3d_compiler.Compile(raw_data(src), uint(len(src)), "load.hlsl", nil, nil, "cs", "cs_5_0", 0, 0, &blob, &errors)) {
		fmt.eprintln("gpuload: shader error")
		os.exit(1)
	}
	cs: ^d3d11.IComputeShader
	dev->CreateComputeShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &cs)
	buf: ^d3d11.IBuffer
	dev->CreateBuffer(&{ByteWidth = 256 * 4, BindFlags = {.UNORDERED_ACCESS}, MiscFlags = {.BUFFER_STRUCTURED}, StructureByteStride = 4}, nil, &buf)
	uav: ^d3d11.IUnorderedAccessView
	dev->CreateUnorderedAccessView(buf, &{Format = .UNKNOWN, ViewDimension = .BUFFER, Buffer = {FirstElement = 0, NumElements = 256}}, &uav)
	query: ^d3d11.IQuery
	dev->CreateQuery(&{Query = .EVENT}, &query)
	ctx->CSSetShader(cs, nil, 0)
	ctx->CSSetUnorderedAccessViews(0, 1, &uav, nil)

	start := time.tick_now()
	n := 0
	for time.duration_seconds(time.tick_since(start)) < f64(seconds) {
		ctx->Dispatch(u32(groups), 1, 1)
		ctx->End(query)
		ctx->Flush()
		done: win.BOOL
		for ctx->GetData(query, &done, size_of(done), 0) != 0 { time.sleep(100 * time.Microsecond) }
		n += 1
		if idle_ms > 0 { time.sleep(time.Duration(idle_ms) * time.Millisecond) }
	}
	fmt.printf("gpuload: %d dispatches of %d groups in %d s\n", n, groups, seconds)
}
