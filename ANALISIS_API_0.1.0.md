# Análisis de igualdad, hashing y rendimiento — Z-Equality 0.1.0

Fecha: 2026-10-12. Compilador: Zig 0.17.0. Entorno de comprobación: Linux x86_64.

Este documento conserva hallazgos para una sesión futura. **Las correcciones y optimizaciones propuestas aquí no se han aplicado.** Los cambios de la migración a Zig 0.17.0 son independientes. Este informe no se enlaza desde el README y no se incluye en el paquete definido por `build.zig.zon`.

## Cómo reproducir los ejemplos

Cada bloque Zig siguiente es un archivo independiente. Guárdalo como `/tmp/caso.zig` y, desde la raíz de este repositorio, ejecuta:

```bash
zig test --dep zequality -Mroot=/tmp/caso.zig -Mzequality=src/zequality.zig
```

Los casos señalados como errores de compilación deben fallar: son reproducciones de limitaciones actuales, no ejemplos de uso correcto. Los otros casos comprueban el comportamiento actual, aunque este sea sorprendente. Las optimizaciones todavía no tienen benchmarks ni porcentajes de mejora medidos.

## Resumen de las funciones públicas

| Función | Comportamiento | Coste habitual |
| --- | --- | --- |
| `strictEquals(T, a, b)` | Igualdad directa de escalares y direcciones; contenido para arrays/slices; métodos propios o `std.meta.eql` para contenedores. | O(1) en escalares; hasta O(n) en secuencias de escalares, con salida temprana. |
| `sameValueZero(T, a, b)` | Añade igualdad entre NaNs; recurre por optionals, arrays y slices, pero no por campos de structs/uniones mediante el fallback. | Igual que la comparación estricta, con comprobación de NaN en flotantes. |
| `hash(T, value)` | Wyhash, normalización de NaN/ceros y despacho por tipo. | O(1) en escalares de tamaño fijo; O(n) en bytes/secuencias de escalares; depende de los métodos propios. |
| `HashContext(T)` | Tipo sin campos que adapta igualdad y hash a `std.HashMap`. | Despacho pequeño; hereda el coste de las funciones anteriores. |
| `hasCustomEql(T)` | Detecta una función pública `eql` de dos parámetros. | Reflexión resuelta en compilación en el despacho interno. |
| `hasCustomHash(T)` | Detecta una función pública `hash` de un parámetro. | Reflexión resuelta en compilación en el despacho interno. |

En datos anidados, n debe entenderse como el contenido recorrido; un elemento puede tener coste adicional. Un método personalizado puede tener cualquier complejidad.

## 1. SameValueZero no se propaga a campos de structs y uniones

Ubicación: `sameValueZero` y `containerEquals` en `src/zequality.zig`.

`sameValueZero` acaba llamando a `strictEquals` para contenedores. Sin método propio, `std.meta.eql` compara sus campos flotantes con igualdad ordinaria. Por ello un NaN se comporta de forma diferente según esté directamente en un array/slice/optional o en un struct/unión.

```zig
const std = @import("std");
const e = @import("zequality");

test "NaN directo y dentro de un struct" {
    const nan = std.math.nan(f64);
    const Point = struct { x: f64 };
    const p = Point{ .x = nan };
    try std.testing.expect(e.sameValueZero(f64, nan, nan));
    try std.testing.expect(!e.sameValueZero(Point, p, p)); // Actual: false.
}
```

**Confirmado:** el ejemplo pasa. Si el contrato pretendido es SameValueZero recursivo, el segundo resultado es incorrecto. Si los contenedores delegan intencionalmente su semántica, se trata de una limitación que debe seguir documentada.

**Propuesta:** decidir el contrato antes de cambiarlo. Si se elige recursividad, comparar campos y payloads mediante la modalidad correspondiente. No reemplazar los métodos propios sin decidir cómo manejar NaN en esos métodos. Añadir pruebas para structs, uniones, arrays y optionals anidados. Cambiar esta semántica puede cambiar la identidad de claves existentes.

## 2. El fallback de hashing rechaza campos flotantes y slices

Ubicación: `containerHash`, que llama a `std.hash.autoHash`.

La igualdad acepta estos contenedores, pero hashing no acepta todos los mismos tipos. Tener un struct válido para `strictEquals` no garantiza que pueda usarse con `HashContext`.

```zig
const e = @import("zequality");

test "hash de struct con float" {
    const Point = struct { x: f64 };
    _ = e.hash(Point, .{ .x = 1.0 });
}
```

**Confirmado:** falla al compilar con `unable to hash type f64`.

```zig
const e = @import("zequality");

test "hash de struct con slice" {
    const Item = struct { text: []const u8 };
    _ = e.hash(Item, .{ .text = "hello" });
}
```

**Confirmado:** falla al compilar porque `std.hash.autoHash` rechaza slices y contenedores que los incluyen. Lo mismo puede afectar a uniones etiquetadas.

**Propuesta:** implementar un fallback coherente con la igualdad elegida. Si la igualdad de slices dentro de structs sigue siendo por dirección y longitud, el hash debe respetar esa semántica; no introducir hashing por contenido indiscriminadamente, especialmente si esos bytes pueden cambiar. Si se cambia a igualdad por contenido, adaptar ambas operaciones juntas. Incorporar el tag de las uniones y pruebas del contrato `eql(a,b) => hash(a)==hash(b)`.

**Alternativa de uso actual:** definir métodos públicos `eql(a: T, b: T) bool` y `hash(self: T) u64` compatibles.

## 3. El hashing de f80 incluye padding de almacenamiento

Ubicación: `hashFloat`, en `hasher.update(std.mem.asBytes(&bits))`.

El entero `u80` usado para representar `f80` tiene 80 bits significativos, pero en el entorno comprobado ocupa 16 bytes. La función procesa los 16 bytes, incluyendo padding que no representa el valor.

```zig
const std = @import("std");

test "representacion de u80 en Linux x86_64" {
    try std.testing.expectEqual(@as(usize, 80), @bitSizeOf(f80));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(u80));
    try std.testing.expect(!std.meta.hasUniqueRepresentation(u80));
}
```

**Confirmado:** las tres comprobaciones pasan en este entorno. **No se demostró experimentalmente un hash diferente para dos valores iguales**; el defecto identificado es incluir bytes que no forman parte del valor. Las pruebas existentes de NaN y cero pueden pasar y aun así no descartar este problema.

**Propuesta:** serializar explícitamente los bits significativos, sin padding, con una estrategia que también contemple endianness. Evitar asumir que cortar los primeros diez bytes sirve en todos los destinos. Añadir comprobaciones de estabilidad con valores obtenidos en ejecución y distintos modos de optimización. Hasta entonces, evitar claves `f80`.

## 4. Las ramas comptime de hash no funcionan

Ubicación: `hash` y `hashFloat`.

El switch enumera `comptime_int` y `comptime_float`, pero sus implementaciones necesitan una representación concreta o llaman a un hasher que rechaza esos tipos.

```zig
const e = @import("zequality");

test "hash de comptime_int" {
    _ = e.hash(comptime_int, 5);
}
```

**Confirmado:** falla con `unable to hash type comptime_int`.

```zig
const e = @import("zequality");

test "hash de comptime_float" {
    _ = e.hash(comptime_float, 1.5);
}
```

**Confirmado:** falla con `no bit size available for type 'comptime_float'`.

**Uso correcto actual:** `hash(i32, 5)` o `hash(f64, 1.5)`.

**Propuesta:** eliminar el soporte aparente y emitir un diagnóstico explícito que pida un tipo concreto, o diseñar una representación canónica. No convertir todo a `i64`/`f64` automáticamente: puede perder rango o precisión.

## 5. Un método hash sin eql se detecta, pero se ignora

Ubicación: `hasCustomHash` y `containerHash`.

La llamada al método propio está dentro de la rama `hasCustomEql(T)`. La existencia de `hash` por sí sola no activa ese despacho.

```zig
const std = @import("std");
const e = @import("zequality");
const Key = struct {
    x: u32,
    pub fn hash(_: @This()) u64 { return 42; }
};

test "hash propio ignorado" {
    try std.testing.expect(e.hasCustomHash(Key));
    try std.testing.expect(e.hash(Key, .{ .x = 7 }) != 42);
}
```

**Confirmado:** pasa con Zig 0.17.0. Es una discrepancia entre detección y utilización, no una violación automática del contrato de igualdad/hash.

**Propuesta:** decidir si un método hash independiente está permitido o exigir el par. Si se permite, despacharlo independientemente y documentar la responsabilidad de mantener coherencia con el fallback de igualdad. Si se exige el par, proporcionar un diagnóstico explícito.

## 6. Los detectores validan cantidad de parámetros, no la firma

Ubicación: `hasCustomEql` y `hasCustomHash`.

Un método con parámetros de tipos incorrectos devuelve true. La llamada posterior puede fallar al compilar con un mensaje menos claro.

```zig
const std = @import("std");
const e = @import("zequality");
const Wrong = struct {
    pub fn eql(_: u32, _: u32) bool { return true; }
    pub fn hash(_: u32) u64 { return 0; }
};

test "firmas incompatibles aceptadas por los detectores" {
    try std.testing.expect(e.hasCustomEql(Wrong));
    try std.testing.expect(e.hasCustomHash(Wrong));
    // e.strictEquals(Wrong, .{}, .{}) no puede llamar eql(u32, u32).
}
```

**Propuesta:** validar tipos de argumentos y retorno, así como la política para funciones genéricas y receptores por puntero. Si solo se admiten las firmas documentadas, exigir `eql(T,T) bool` y `hash(T) u64`. Es una mejora de diagnóstico/corrección, no una optimización importante de ejecución.

## 7. Oportunidades de rendimiento pendientes de medición

### 7.1. Evitar hashing doble por elemento

En `hashSlice`, para tipos distintos de `u8`, cada elemento crea/finaliza un Wyhash mediante `hash(E,item)` y el hasher exterior vuelve a procesar ese resultado de 64 bits.

Ejemplo: un `[]i32` de 1.000 elementos ejecuta 1.000 hashes individuales y un hash exterior; el resultado exige recorrer toda la secuencia. Para slices anidados, se repite el patrón en cada nivel.

**Propuesta:** un helper interno que alimente un único hasher con una representación coherente de los valores. Mantener normalización de NaN/ceros, no leer padding y respetar métodos personalizados. Para bytes, conservar el camino directo actual. Los resultados numéricos de los hashes cambiarían; no prometer compatibilidad con hashes persistidos.

### 7.2. Usar caminos optimizados para comparación de tipos seguros

Los slices `u8` ya usan `std.mem.eql`. Los arrays `u8` y slices de enteros recorren elemento por elemento mediante el helper genérico.

**Propuesta:** evaluar `std.mem.eql` en esos casos. No aplicar comparación binaria a structs, optionals o flotantes sin demostrar equivalencia semántica. No usar una salida automática por dirección idéntica para todos los tipos: un slice que contiene NaN puede ser distinto de sí mismo bajo igualdad estricta; los comparadores personalizados tampoco tienen reflexividad garantizada.

### 7.3. No optimizar prematuramente escalares y reflexión

Las comparaciones escalares ya son directas y el despacho depende de tipos conocidos en compilación. Forzar inline, reemplazar Wyhash por un mezclador casero o cachear decisiones de reflexión no tiene beneficio demostrado y puede empeorar tamaño de código, calidad del hash o rendimiento.

## Plan para la siguiente sesión

1. Definir el contrato de igualdad en contenedores y métodos propios.
2. Corregir padding de f80 y diagnósticos de tipos comptime.
3. Hacer coherentes fallback de igualdad, hashing y despacho de métodos.
4. Añadir regresiones para los hallazgos confirmados, incluidos usos reales en HashMap.
5. Medir antes/después en `-Doptimize=fast`: slices de 0, 1, 16, 256 y 4.096 elementos; bytes, enteros y floats; igualdad completa y diferencias al principio/final; cargas con NaN/ceros y claves personalizadas.
6. Incluir inserción y búsqueda de HashMap, consumo observable de resultados y datos obtenidos en ejecución para evitar que el compilador elimine el trabajo. Registrar CPU, versión, repeticiones y dispersión.
7. Aplicar optimizaciones solo si mantienen el contrato y mejoran los casos medidos.

## Evidencia y límites

Se consultaron `src/zequality.zig`, los tests y las implementaciones instaladas de Zig 0.17.0: `std.meta.eql`, `std.hash.autoHash` y `std.lang.Type.Fn`. Se ejecutaron siete comprobaciones temporales: NaN anidado, rechazo de hashing de structs con float/slice, rechazo de ambos tipos comptime, método hash independiente ignorado y representación de u80. El ejemplo de firmas incompatibles se valida también durante la preparación de este informe. No se midió rendimiento ni se reprodujo inestabilidad efectiva de f80; ambas cosas quedan pendientes.
