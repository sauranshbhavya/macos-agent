import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

/**
 * A thin MCP stdio connection to `cua-driver mcp`. Every tool call comes back as the driver's own
 * JSON (`structuredContent` when the driver sends it, else the first text block parsed as JSON), so
 * the layer above can validate it with Zod before trusting a single field.
 */
export type ToolCall = (name: string, args: Record<string, unknown>) => Promise<unknown>;

export interface McpToolResult {
  isError: boolean;
  payload: unknown;
}

const HERE = dirname(fileURLToPath(import.meta.url));

/** The binary `scripts/fetch-cua-driver.sh` unpacks, unless CUA_DRIVER_BIN points elsewhere. */
export function driverBinaryPath(): string {
  return process.env["CUA_DRIVER_BIN"] ?? resolve(HERE, "../../.cua-driver/cua-driver");
}

export class McpDriverConnection {
  #client: Client;
  #transport: StdioClientTransport;

  private constructor(client: Client, transport: StdioClientTransport) {
    this.#client = client;
    this.#transport = transport;
  }

  static async open(binary: string = driverBinaryPath()): Promise<McpDriverConnection> {
    const transport = new StdioClientTransport({
      command: binary,
      args: ["mcp"],
      stderr: "pipe",
    });
    const client = new Client({ name: "jev-cua-experiment", version: "0.1.0" });
    await client.connect(transport);
    return new McpDriverConnection(client, transport);
  }

  async call(name: string, args: Record<string, unknown>): Promise<McpToolResult> {
    const result = await this.#client.callTool({ name, arguments: args });
    const isError = result.isError === true;
    if (result.structuredContent !== undefined) {
      return { isError, payload: result.structuredContent };
    }
    const content = Array.isArray(result.content) ? result.content : [];
    const text = content.find((c): c is { type: "text"; text: string } => c.type === "text");
    if (text === undefined) {
      return { isError, payload: null };
    }
    try {
      return { isError, payload: JSON.parse(text.text) as unknown };
    } catch {
      return { isError, payload: { text: text.text } };
    }
  }

  async listTools(): Promise<string[]> {
    const { tools } = await this.#client.listTools();
    return tools.map((t) => t.name);
  }

  async close(): Promise<void> {
    await this.#transport.close();
  }
}
