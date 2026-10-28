# Guía de uso

Resumen corto. El detalle y las explicaciones están en el [README](README.md); lo que hay que tener instalado, en [REQUISITOS.md](REQUISITOS.md).

## Primera vez

1. Instala lo de [REQUISITOS.md](REQUISITOS.md) y descarga los dos modelos (`ollama pull bge-m3` y `ollama pull qwen3:4b-instruct`).
2. Arranca Caddy en una ventana de PowerShell que quede abierta:
   ```powershell
   caddy run --config ai\caddy\Caddyfile
   ```
   La primera vez, confía en su certificado (README, paso 4.3).
3. Comprueba el entorno. Solo lee, no cambia nada:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\scripts\check-env.ps1
   ```
4. Crea la base de datos y ejecuta todos los scripts y pruebas:
   ```powershell
   .\scripts\instalar.ps1
   ```
   La salida de cada script queda en `evidencias\`.

## Cada vez que enciendas el ordenador

1. SQL Server y Ollama arrancan solos con Windows.
2. Arranca Caddy (ventana 1): `caddy run --config ai\caddy\Caddyfile`
3. Arranca la app (ventana 2): `.\scripts\abrir-app.ps1`
4. Abre <http://127.0.0.1:5080> si el navegador no se abre solo.
5. Para cerrar, Ctrl+C en las dos ventanas.

## Usar la app

- **Archivar:** arrastra uno o varios PDF. La app lee el texto, guarda el original y la IA local lo clasifica. Un PDF escaneado (sin texto) no se archiva y la app lo avisa.
- **Preguntar:** escribe una pregunta en lenguaje normal.
  - Sobre contenido: "¿Con cuánto preaviso puedo dejar la oficina?" Responde con la fuente (`archivo · p. N`) y el pasaje resaltado.
  - Sobre cifras: "¿Cuánto he pagado a Tecnologías Arganzuela este año?" La suma la calcula SQL Server, no el modelo. La respuesta indica la cuenta y si las cifras se comprobaron.
- **Documentos:** lista con filtros, ficha con los campos leídos, el PDF original y el borrado definitivo de un documento.
- **Ver como:** cambia el departamento con el que se consulta. Contabilidad no ve los contratos.

## Probar con documentos de ejemplo

En `demo\pdfs-prueba\` hay tres PDF inventados: dos facturas y un contrato. Súbelos desde "Archivar" y prueba las preguntas del README.

## Sin la app, solo con SQL

Abre `demo\demo.sql` en SSMS y ejecuta los bloques. Es el recorrido completo: búsqueda por significado, preguntas con cita, preguntas de datos y seguridad por departamento.

## Si algo falla

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| "La ejecución de scripts está deshabilitada" | Política de PowerShell | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| La app responde "no se pudo responder" | Caddy u Ollama parados | `.\scripts\check-env.ps1` |
| La primera pregunta tarda 1–2 minutos | Ollama carga el modelo en memoria | Es normal, las siguientes son más rápidas |
| Error de certificado al llamar al modelo | Falta confiar en el certificado de Caddy | README, paso 4.3 |
