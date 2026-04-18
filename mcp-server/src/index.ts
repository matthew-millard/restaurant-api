import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const API_BASE = process.env.MCP_API_BASE_URL || "http://localhost:3000";

async function apiRequest(
  path: string,
  options: RequestInit = {}
): Promise<unknown> {
  const response = await fetch(`${API_BASE}${path}`, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`API ${response.status}: ${body}`);
  }

  return response.json();
}

const server = new McpServer({
  name: "restaurant-mcp-server",
  version: "1.0.0",
});

server.tool(
  "get_menu",
  "Returns all available menu items with prices, grouped by category",
  async () => {
    const data = await apiRequest("/api/v1/menu");
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
);

server.tool(
  "place_order",
  "Place a new order. Requires customer name, email, pickup time, and at least one item.",
  {
    customer_name: z.string().describe("Customer's full name"),
    customer_email: z.string().email().describe("Customer's email address"),
    pickup_time: z.string().describe("Requested pickup time, e.g. '7:00 PM'"),
    items: z
      .array(
        z.object({
          menu_item_id: z.number().describe("ID of the menu item"),
          quantity: z.number().min(1).describe("Quantity to order"),
          modifications: z
            .string()
            .optional()
            .describe("Special requests, e.g. 'No pickles'"),
        })
      )
      .min(1)
      .describe("Items to order"),
  },
  async (args) => {
    const data = await apiRequest("/api/v1/orders", {
      method: "POST",
      body: JSON.stringify({ order: args }),
    });
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
);

server.tool(
  "track_order",
  "Get the status and details of an existing order by its ID",
  {
    order_id: z.string().uuid().describe("The order UUID"),
  },
  async (args) => {
    const data = await apiRequest(`/api/v1/orders/${args.order_id}`);
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
);

server.tool(
  "cancel_order",
  "Cancel a pending order by its ID",
  {
    order_id: z.string().uuid().describe("The order UUID to cancel"),
  },
  async (args) => {
    const data = await apiRequest(`/api/v1/orders/${args.order_id}/cancel`, {
      method: "PATCH",
    });
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Restaurant MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
