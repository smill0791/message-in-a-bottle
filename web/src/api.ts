export interface User {
    id: string;
    handle: string;
    isModerator: boolean;
}

export interface QueueItem {
    id: string;
    body: string;
    created_at: string;
    author: string;
    open_reports: number;
    reasons: string[];
    discovery_count: number;
    previously_reviewed: boolean;
}

export interface Bottle {
    id: string;
    slot: number;
}

export interface BeachResponse {
    bottles: Bottle[];
    empty: boolean;
}

export interface OpenedLetter {
    id: string;
    body: string;
    writtenAt: string;
    firstTime: boolean;
}

export interface KeptMessage {
    id: string;
    body: string;
    discovered_at: string;
    favorited: boolean;
    theme: Theme | null;
}

export interface OwnMessage {
    id: string;
    body: string;
    status: "pending" | "approved" | "rejected";
    created_at: string;
    discovery_count: number;
    resonated_count: number;
}

export const THEMES = [
    "encouraging",
    "uplifting",
    "reflective",
    "grateful",
    "hopeful",
    "sad",
] as const;

export type Theme = (typeof THEMES)[number];

export const MAX_BODY = 500;

export class ApiError extends Error {
    constructor(
        message: string,
        readonly status: number,
        /** Per-field validation messages, when the server sent them. */
        readonly fields?: Record<string, string>,
    ) {
        super(message);
    }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
    const res = await fetch(path, {
        ...init,
        // Session cookie is httpOnly; it rides along on same-origin requests.
        credentials: "same-origin",
        headers: init?.body ? { "content-type": "application/json" } : undefined,
    });

    const text = await res.text();
    const data = text ? (JSON.parse(text) as unknown) : null;

    if (!res.ok) {
        const payload = (data ?? {}) as { error?: unknown; fields?: Record<string, string> };
        const message = payload.error ? String(payload.error) : "Something went wrong.";
        throw new ApiError(message, res.status, payload.fields);
    }

    return data as T;
}

export const api = {
    me: () => request<User>("/auth/me"),

    register: (handle: string, password: string) =>
        request<User>("/auth/register", {
            method: "POST",
            body: JSON.stringify({ handle, password }),
        }),

    login: (handle: string, password: string) =>
        request<User>("/auth/login", {
            method: "POST",
            body: JSON.stringify({ handle, password }),
        }),

    logout: () => request<{ ok: boolean }>("/auth/logout", { method: "POST" }),

    beach: () => request<BeachResponse>("/beach"),

    open: (id: string) => request<OpenedLetter>(`/beach/${id}/open`, { method: "POST" }),

    write: (body: string) =>
        request<{ id: string; message: string }>("/messages", {
            method: "POST",
            body: JSON.stringify({ body }),
        }),

    mine: () => request<{ messages: OwnMessage[] }>("/messages/mine"),

    chest: () => request<{ messages: KeptMessage[] }>("/chest"),

    keep: (id: string, saved: boolean) =>
        request<{ saved: boolean }>(`/chest/${id}`, {
            method: "PUT",
            body: JSON.stringify({ saved }),
        }),

    favorite: (id: string, favorited: boolean) =>
        request<{ favorited: boolean }>(`/chest/${id}/favorite`, {
            method: "PUT",
            body: JSON.stringify({ favorited }),
        }),

    rate: (id: string, theme: Theme, resonated: boolean) =>
        request<{ theme: Theme }>(`/chest/${id}/rating`, {
            method: "PUT",
            body: JSON.stringify({ theme, resonated }),
        }),

    queue: () => request<{ queue: QueueItem[] }>("/admin/queue"),

    summary: () => request<{ pending: number; reported: number }>("/admin/summary"),

    approve: (id: string) =>
        request<{ status: string }>(`/admin/messages/${id}/approve`, { method: "POST" }),

    reject: (id: string) =>
        request<{ status: string }>(`/admin/messages/${id}/reject`, { method: "POST" }),

    report: (id: string, reason: string) =>
        request<{ ok: boolean }>(`/messages/${id}/report`, {
            method: "POST",
            body: JSON.stringify({ reason }),
        }),
};
