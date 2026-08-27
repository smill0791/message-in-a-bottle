import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The API is a separate process on :3000 in development. In Phase 1 the built
// assets are served by the same origin behind the ALB, so these proxy rules
// exist only for local work and the app always talks to same-origin paths.
const apiPaths = ["/auth", "/beach", "/chest", "/messages", "/healthz", "/readyz"];

export default defineConfig({
    plugins: [react()],
    server: {
        port: 5173,
        proxy: Object.fromEntries(
            apiPaths.map((p) => [p, { target: "http://127.0.0.1:3000", changeOrigin: true }]),
        ),
    },
    build: {
        outDir: "dist",
        sourcemap: true,
    },
});
