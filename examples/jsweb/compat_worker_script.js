// The worker of compat.js: the pieces of the compat set that Workers have (fonts, permissions) and the ones they do not.
onmessage = async () => {
  const r = [];
  r.push(self.fonts instanceof FontFaceSet, self.fonts === self.fonts, self.fonts.status, (await self.fonts.ready) === self.fonts);
  const st = await navigator.permissions.query({ name: "clipboard-write" });
  r.push(st instanceof PermissionStatus, st.name, st.state, navigator.permissions === navigator.permissions);
  r.push(typeof VisualViewport, typeof alert, typeof Element, typeof self.visualViewport);
  postMessage(r.join());
};
