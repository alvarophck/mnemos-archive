// Tema: sistema -> Paper -> Night archive -> sistema. Se recuerda en este navegador.
// El tema inicial se aplica en <head> (App.razor) para que la página no parpadee.
(function () {
  const orden = ["sistema", "paper", "night"];

  function leer() {
    try { return localStorage.getItem("mnemos-tema") || "sistema"; } catch { return "sistema"; }
  }

  function aplicar(tema) {
    if (tema === "sistema") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", tema);
    document.querySelectorAll("[data-accion='tema']").forEach(function (b) {
      const nombre = b.getAttribute("data-nombre-" + tema) || tema;
      b.setAttribute("aria-label", b.getAttribute("data-prefijo") + ": " + nombre);
      b.setAttribute("title", b.getAttribute("data-prefijo") + ": " + nombre);
    });
  }

  document.addEventListener("click", function (e) {
    const boton = e.target.closest("[data-accion='tema']");
    if (!boton) return;
    const siguiente = orden[(orden.indexOf(leer()) + 1) % orden.length];
    try { localStorage.setItem("mnemos-tema", siguiente); } catch { /* sin almacenamiento: solo esta página */ }
    aplicar(siguiente);
  });

  // Blazor vuelve a pintar la cabecera al navegar: se refrescan las etiquetas del botón
  new MutationObserver(function () { aplicar(leer()); })
    .observe(document.documentElement, { childList: true, subtree: true });
  aplicar(leer());
})();
