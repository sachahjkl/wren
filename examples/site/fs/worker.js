// tools\fs_e2e.ps1: a sync access handle in a dedicated worker (read, write, truncate, getSize, flush, close, the
// exclusive lock), and a handle received in a message.
self.onmessage = async (e) => {
  const out = [];
  try {
    const root = await navigator.storage.getDirectory();
    const f = await root.getFileHandle("sync.bin", {create: true});
    const h = await f.createSyncAccessHandle();
    out.push(await f.createSyncAccessHandle().then(() => "second", (x) => x.name));
    const enc = new TextEncoder();
    h.write(enc.encode("hello world"));
    h.write(enc.encode("HELLO"), {at: 0});
    out.push(h.getSize());
    const buf = new Uint8Array(5);
    h.read(buf, {at: 6});
    out.push(new TextDecoder().decode(buf));
    h.truncate(5);
    h.flush();
    out.push(h.getSize());
    out.push(await root.removeEntry("sync.bin").then(() => "removed", (x) => x.name));
    h.close();
    out.push(await root.removeEntry("sync.bin").then(() => "removed", (x) => x.name));
    out.push(e.data instanceof FileSystemFileHandle ? await (await e.data.getFile()).text() : "no handle");
  } catch (x) { out.push("error " + x.name + " " + x.message); }
  postMessage(out.join(" "));
};
