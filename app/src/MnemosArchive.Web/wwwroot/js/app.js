// Utilidades mínimas para la interfaz.
window.mnemos = {
  // Lleva la vista a un elemento (la página citada) y le da el foco para lectores de pantalla
  irA: function (id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.scrollIntoView({ block: "start" });
    el.focus({ preventScroll: true });
  }
};
