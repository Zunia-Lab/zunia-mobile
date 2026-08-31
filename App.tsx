import { StatusBar } from "expo-status-bar";
import { StyleSheet, Text, View } from "react-native";

export default function App() {
  return (
    <View style={styles.container}>
      <Text style={styles.brand}>zunia</Text>
      <Text style={styles.tagline}>
        Multi-chain Cosmos wallet. Same keys as the extension.
      </Text>
      <StatusBar style="light" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#10214F",
    alignItems: "center",
    justifyContent: "center",
    padding: 24,
  },
  brand: {
    color: "#F4F5F7",
    fontSize: 36,
    fontWeight: "500",
    letterSpacing: -1.5,
  },
  tagline: {
    marginTop: 12,
    color: "#A8BADE",
    fontSize: 16,
    textAlign: "center",
    lineHeight: 24,
  },
});
