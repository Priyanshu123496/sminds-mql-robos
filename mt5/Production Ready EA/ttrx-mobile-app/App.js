import React, { useMemo, useState } from "react";
import {
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { StatusBar } from "expo-status-bar";

function toInt(v) {
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? 0 : n;
}

function encodeFast(fast) {
  return ((fast + 11) * 17) ^ 913;
}

function decodeFast(code) {
  const t = code ^ 913;
  if (t <= 0 || t % 17 !== 0) return null;
  const val = t / 17 - 11;
  return val > 0 ? val : null;
}

function encodeSlow(slow) {
  return ((slow + 17) * 19) ^ 1291;
}

function decodeSlow(code) {
  const t = code ^ 1291;
  if (t <= 0 || t % 19 !== 0) return null;
  const val = t / 19 - 17;
  return val > 0 ? val : null;
}

function encodeFilter(filter) {
  return ((filter + 23) * 29) ^ 2087;
}

function decodeFilter(code) {
  const t = code ^ 2087;
  if (t <= 0 || t % 29 !== 0) return null;
  const val = t / 29 - 23;
  return val > 0 ? val : null;
}

export default function App() {
  const [fast, setFast] = useState("9");
  const [slow, setSlow] = useState("15");
  const [filter, setFilter] = useState("200");
  const [p2, setP2] = useState("709");
  const [p3, setP3] = useState("1899");
  const [p4, setP4] = useState("4452");

  const encoded = useMemo(() => {
    const f = toInt(fast);
    const s = toInt(slow);
    const fl = toInt(filter);
    if (f <= 0 || s <= 0 || fl <= 0) return null;
    return {
      p2: encodeFast(f),
      p3: encodeSlow(s),
      p4: encodeFilter(fl),
    };
  }, [fast, slow, filter]);

  const decoded = useMemo(() => {
    const c2 = decodeFast(toInt(p2));
    const c3 = decodeSlow(toInt(p3));
    const c4 = decodeFilter(toInt(p4));
    return {
      fast: c2,
      slow: c3,
      filter: c4,
      valid: c2 !== null && c3 !== null && c4 !== null,
    };
  }, [p2, p3, p4]);

  const useEncodedDefaults = () => {
    setP2("709");
    setP3("1899");
    setP4("4452");
  };

  return (
    <SafeAreaView style={styles.safe}>
      <StatusBar style="dark" />
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>TTR-X Parameter Helper</Text>
        <Text style={styles.subtitle}>Encode and decode InpP2 / InpP3 / InpP4</Text>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Encode EMA -> InpP values</Text>
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={fast}
            onChangeText={setFast}
            placeholder="Fast EMA"
          />
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={slow}
            onChangeText={setSlow}
            placeholder="Slow EMA"
          />
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={filter}
            onChangeText={setFilter}
            placeholder="Filter EMA"
          />

          <View style={styles.resultBox}>
            <Text style={styles.resultText}>InpP2: {encoded ? encoded.p2 : "-"}</Text>
            <Text style={styles.resultText}>InpP3: {encoded ? encoded.p3 : "-"}</Text>
            <Text style={styles.resultText}>InpP4: {encoded ? encoded.p4 : "-"}</Text>
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Decode InpP values -> EMA</Text>
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={p2}
            onChangeText={setP2}
            placeholder="InpP2"
          />
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={p3}
            onChangeText={setP3}
            placeholder="InpP3"
          />
          <TextInput
            style={styles.input}
            keyboardType="number-pad"
            value={p4}
            onChangeText={setP4}
            placeholder="InpP4"
          />

          <View style={styles.resultBox}>
            <Text style={styles.resultText}>Fast EMA: {decoded.fast ?? "Invalid code"}</Text>
            <Text style={styles.resultText}>Slow EMA: {decoded.slow ?? "Invalid code"}</Text>
            <Text style={styles.resultText}>Filter EMA: {decoded.filter ?? "Invalid code"}</Text>
          </View>

          <TouchableOpacity style={styles.button} onPress={useEncodedDefaults}>
            <Text style={styles.buttonText}>Use 9 / 15 / 200 Defaults</Text>
          </TouchableOpacity>

          <Text style={styles.hint}>
            {decoded.valid
              ? "Codes are valid for current formula."
              : "One or more values do not match TTR-X formula."}
          </Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: "#f4f6f8",
  },
  container: {
    padding: 20,
    gap: 14,
  },
  title: {
    fontSize: 28,
    fontWeight: "700",
    color: "#13233a",
  },
  subtitle: {
    fontSize: 14,
    color: "#4c5c70",
    marginBottom: 4,
  },
  card: {
    backgroundColor: "#ffffff",
    borderRadius: 14,
    padding: 14,
    borderWidth: 1,
    borderColor: "#dde3ea",
    gap: 10,
  },
  cardTitle: {
    fontSize: 16,
    fontWeight: "700",
    color: "#13233a",
  },
  input: {
    borderWidth: 1,
    borderColor: "#ccd6e0",
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 16,
    backgroundColor: "#fbfcfd",
  },
  resultBox: {
    backgroundColor: "#0d1b2a",
    borderRadius: 10,
    padding: 12,
    gap: 6,
  },
  resultText: {
    color: "#d6f2ff",
    fontSize: 15,
    fontWeight: "600",
  },
  button: {
    backgroundColor: "#0066cc",
    borderRadius: 10,
    paddingVertical: 10,
    alignItems: "center",
  },
  buttonText: {
    color: "#ffffff",
    fontWeight: "700",
  },
  hint: {
    fontSize: 12,
    color: "#4c5c70",
  },
});
