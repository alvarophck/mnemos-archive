/* =====================================================================
   Mnemos Archive · ai/04_vector_search.sql
   Bloque F: búsqueda por significado (vector search).

   Pregunta -> embedding (bge-m3) -> VECTOR_DISTANCE coseno contra todos
   los fragmentos -> ranking de documentos.

   Por qué coseno: mide el ángulo entre vectores e ignora su longitud,
   que en un embedding de texto no aporta significado. bge-m3 está
   entrenado para comparar con coseno. Distancia 0 = misma dirección;
   la mostramos como similitud = 1 - distancia.

   Búsqueda exacta (kNN) a propósito: con unos cientos de fragmentos
   recorrerlos todos tarda milisegundos y el resultado es exacto.
   El índice aproximado DiskANN (preview) compensa a partir de decenas
   de miles de filas y exige un mínimo de 100; ver el final del script.
   ===================================================================== */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
USE MnemosArchive;
GO

CREATE OR ALTER PROCEDURE archivo.usp_buscar_semantica
    @consulta nvarchar(1000),
    @top      int         = 5,
    @tipo     varchar(20) = NULL     -- opcional: solo facturas, solo contratos...
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @q vector(1024) = AI_GENERATE_EMBEDDINGS(@consulta USE MODEL modelo_embeddings);

    WITH candidatos AS
    (
        SELECT f.documento_id, f.pagina, f.texto,
               VECTOR_DISTANCE('cosine', f.embedding, @q) AS distancia
        FROM archivo.fragmentos AS f          -- Row-Level Security se aplica aquí también
        WHERE f.embedding IS NOT NULL
    ),
    mejor_por_documento AS
    (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY documento_id ORDER BY distancia) AS n
        FROM candidatos
    )
    SELECT TOP (@top)
           ROW_NUMBER() OVER (ORDER BY m.distancia)        AS posicion,
           CAST(1 - m.distancia AS decimal(5,4))           AS similitud,
           d.nombre_archivo,
           d.tipo,
           t.nombre                                        AS tercero,
           m.pagina,
           LEFT(REPLACE(m.texto, NCHAR(10), N' '), 160)    AS fragmento
    FROM mejor_por_documento AS m
    JOIN archivo.documentos AS d ON d.documento_id = m.documento_id
    LEFT JOIN archivo.terceros AS t ON t.tercero_id = d.tercero_id
    WHERE m.n = 1
      AND (@tipo IS NULL OR d.tipo = @tipo)
    ORDER BY m.distancia;
END;
GO

/* ---------------------------------------------------------------------
   Demostración: ninguna de estas búsquedas comparte palabras exactas
   con el documento que debería salir primero.
   --------------------------------------------------------------------- */
-- Debería salir el contrato de señalética ("antes del 30 de junio")
EXEC archivo.usp_buscar_semantica @consulta = N'cláusula de entrega antes del verano';

-- Debería salir el contrato de alquiler (cláusula 4, "preaviso", página 2)
EXEC archivo.usp_buscar_semantica @consulta = N'¿con cuánto tiempo tengo que avisar para dejar la oficina?';

-- Gasto en luz: las facturas de Energía Clara
EXEC archivo.usp_buscar_semantica @consulta = N'recibos de la electricidad', @top = 3;

-- Solo facturas, sobre un tema concreto
EXEC archivo.usp_buscar_semantica @consulta = N'trabajos de imprenta y cartelería', @tipo = 'factura';
GO

/* ---------------------------------------------------------------------
   Opcional (preview): índice vectorial aproximado DiskANN.
   Requiere al menos 100 filas con vector. Con los datos de ejemplo
   no hace falta; se deja como referencia para un archivo grande.

   CREATE VECTOR INDEX IX_fragmentos_embedding
       ON archivo.fragmentos (embedding)
       WITH (METRIC = 'cosine', TYPE = 'diskann');

   DECLARE @q vector(1024) = AI_GENERATE_EMBEDDINGS(N'preaviso' USE MODEL modelo_embeddings);
   SELECT TOP (5) WITH APPROXIMATE f.fragmento_id, f.texto, r.distance
   FROM VECTOR_SEARCH(TABLE = archivo.fragmentos AS f, COLUMN = embedding,
                      SIMILAR_TO = @q, METRIC = 'cosine') AS r
   ORDER BY r.distance;
   --------------------------------------------------------------------- */
