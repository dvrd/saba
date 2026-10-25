let connectedBefore = false
let reloading = false

function reloadPage() {
  if (reloading) return
  reloading = true
  location.reload()
}

function connectReload() {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:"
  const socket = new WebSocket(
    `${protocol}//${location.host}/__reload`
  )

  socket.addEventListener("open", () => {
    if (connectedBefore) {
      reloadPage();
      return;
    }

    connectedBefore = true;
  });

  socket.addEventListener("message", (event) => {
    if (event.data === "reload") reloadPage();
  });

  socket.addEventListener("close", () => {
    if (!reloading) setTimeout(connectReload, 500);
  });

  socket.addEventListener("error", () => {
    socket.close();
  });
}

connectReload()
