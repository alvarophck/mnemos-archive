# Requisitos

Mnemos Archive es un proyecto de T-SQL y .NET, no de Python. Por eso no hay `requirements.txt`: lo que necesita está en esta lista.

## Para ejecutarlo

| Programa | Versión | Para qué | Cómo instalarlo |
|---|---|---|---|
| Windows | 11 | Sistema donde se probó | |
| SQL Server | 2025 (17.0), edición Developer | Base de datos, vectores y llamadas al modelo | Instalador de Microsoft |
| SSMS | 21 o 22 | Abrir y ejecutar los scripts a mano (opcional si usas `instalar.ps1`) | Instalador de Microsoft |
| Ollama | reciente | Ejecuta los modelos en local | `winget install Ollama.Ollama` |
| Modelo `bge-m3` | | Embeddings de 1024 dimensiones | `ollama pull bge-m3` |
| Modelo `qwen3:4b-instruct` | | Responde y clasifica | `ollama pull qwen3:4b-instruct` |
| Caddy | 2.x | Puente HTTPS entre SQL Server y Ollama | `winget install CaddyServer.Caddy` |
| PowerShell | 5.1 o superior | Scripts de instalación | Viene con Windows |
| SDK de .NET | 9 | Solo para la app web | `winget install Microsoft.DotNet.SDK.9` |

Opcional: la búsqueda de texto completo de SQL Server (la búsqueda híbrida la usa; sin ella todo funciona con solo vectores).

## Paquetes de la app (se descargan solos al compilar)

| Paquete | Versión | Licencia |
|---|---|---|
| Microsoft.Data.SqlClient | 7.1.1 | MIT |
| PdfPig | 0.1.16 | Apache 2.0 |
| xunit, xunit.runner.visualstudio, Microsoft.NET.Test.Sdk, coverlet.collector | solo para las pruebas | |

Las fuentes Fraunces e IBM Plex (licencia OFL) van dentro de la app.

## Recursos

- Unos 8 GB de RAM libres para el modelo de lenguaje.
- Unos 4 GB de disco para los dos modelos.
- Sin conexión a internet una vez descargado todo. Ninguna cuenta, ninguna clave de API.

## Qué hace cada pieza

La explicación está en el [README](README.md), apartado "Arquitectura". Los pasos para instalarlo, en [GUIA-DE-USO.md](GUIA-DE-USO.md).
