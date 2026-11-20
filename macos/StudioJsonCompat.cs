// .NET 8+ replacement for the small System.Web JavaScriptSerializer surface
// used by Relay's existing, tested board protocol. No protocol paths change.
using System;
using System.Collections.Generic;
using System.Text.Json;

namespace System.Web.Script.Serialization {
    public sealed class JavaScriptSerializer {
        public int MaxJsonLength { get; set; } = 2097152;
        public int RecursionLimit { get; set; } = 32;
        public object DeserializeObject(string json) {
            if (json == null || json.Length > MaxJsonLength) throw new ArgumentException("JSON response is too large.");
            using (var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = RecursionLimit }))
                return Read(document.RootElement);
        }
        private static object Read(JsonElement value) {
            switch (value.ValueKind) {
                case JsonValueKind.Object:
                    var dictionary = new Dictionary<string, object>(StringComparer.Ordinal);
                    foreach (var property in value.EnumerateObject()) dictionary.Add(property.Name, Read(property.Value));
                    return dictionary;
                case JsonValueKind.Array:
                    var array = new List<object>();
                    foreach (var item in value.EnumerateArray()) array.Add(Read(item));
                    return array.ToArray();
                case JsonValueKind.String: return value.GetString();
                case JsonValueKind.Number:
                    if (value.TryGetInt32(out var integer)) return integer;
                    if (value.TryGetInt64(out var large)) return large;
                    return value.GetDouble();
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                case JsonValueKind.Null: return null;
                default: throw new ArgumentException("Unsupported JSON value.");
            }
        }
        public string Serialize(object value) {
            string json = JsonSerializer.Serialize(value, new JsonSerializerOptions { MaxDepth = RecursionLimit });
            if (json.Length > MaxJsonLength) throw new ArgumentException("JSON request is too large.");
            return json;
        }
    }
}
