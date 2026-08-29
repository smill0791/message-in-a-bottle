import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The API is a separate process on :3000 in development. In production the
// built assets are served by the API itself behind the ALB, so this proxy
// exists only for local work - the app always talks to same-origin /api.

export default defineConfig({
    plugins: [react()],
    server: {
        port: 5173,
        proxy: {
            "/api": { target: "http://127.0.0.1:3000", changeOrigin: true },
        },
    },
    build: {
        outDir: "dist",
        sourcemap: true,
    },
});
