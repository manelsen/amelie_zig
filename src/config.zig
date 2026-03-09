const std = @import("std");

pub const Config = struct {
    gemini_api_key: []const u8,
    openrouter_api_key: []const u8,
    usar_openrouter: bool,
    db_path: []const u8,
    whatsapp_webhook_url: []const u8,
    port: u16 = 3000,
    host: []const u8 = "0.0.0.0",

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .gemini_api_key = "",
            .openrouter_api_key = "",
            .usar_openrouter = false,
            .db_path = "./amelie.db",
            .whatsapp_webhook_url = "http://localhost:8080",
            .port = 3000,
            .host = "0.0.0.0",
            .allocator = allocator,
        };
    }

    /// Carregar de variáveis de ambiente
    pub fn fromEnv(self: *Config) !void {
        if (std.posix.getenv("GEMINI_API_KEY")) |key| {
            self.gemini_api_key = try self.allocator.dupe(u8, key);
        }

        if (std.posix.getenv("OPENROUTER_API_KEY")) |key| {
            self.openrouter_api_key = try self.allocator.dupe(u8, key);
        }

        if (std.posix.getenv("USAR_OPENROUTER")) |vl| {
            self.usar_openrouter = std.mem.eql(u8, vl, "true") or std.mem.eql(u8, vl, "1");
        }

        if (std.posix.getenv("DB_PATH")) |path| {
            self.db_path = try self.allocator.dupe(u8, path);
        }

        if (std.posix.getenv("WHATSAPP_WEBHOOK_URL")) |url| {
            self.whatsapp_webhook_url = try self.allocator.dupe(u8, url);
        }

        if (std.posix.getenv("PORT")) |port_str| {
            self.port = try std.fmt.parseInt(u16, port_str, 10);
        }

        if (std.posix.getenv("HOST")) |host| {
            self.host = try self.allocator.dupe(u8, host);
        }
    }

    /// Carregar de arquivo .env
    pub fn fromFile(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const max_size = 4096;
        const content = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq_idx], " \t\r");
            const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r");

            const Key = enum {
                GEMINI_API_KEY,
                OPENROUTER_API_KEY,
                USAR_OPENROUTER,
                DB_PATH,
                WHATSAPP_WEBHOOK_URL,
                PORT,
                HOST,
            };

            const KeyMap = std.StaticStringMap(Key).initComptime(.{
                .{ "GEMINI_API_KEY",        .GEMINI_API_KEY },
                .{ "OPENROUTER_API_KEY",    .OPENROUTER_API_KEY },
                .{ "USAR_OPENROUTER",       .USAR_OPENROUTER },
                .{ "DB_PATH",               .DB_PATH },
                .{ "WHATSAPP_WEBHOOK_URL",  .WHATSAPP_WEBHOOK_URL },
                .{ "PORT",                  .PORT },
                .{ "HOST",                  .HOST },
            });

            if (KeyMap.get(key)) |k| {
                switch (k) {
                    .GEMINI_API_KEY       => self.gemini_api_key = try self.allocator.dupe(u8, value),
                    .OPENROUTER_API_KEY   => self.openrouter_api_key = try self.allocator.dupe(u8, value),
                    .USAR_OPENROUTER      => self.usar_openrouter = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1"),
                    .DB_PATH              => self.db_path = try self.allocator.dupe(u8, value),
                    .WHATSAPP_WEBHOOK_URL => self.whatsapp_webhook_url = try self.allocator.dupe(u8, value),
                    .PORT                 => self.port = try std.fmt.parseInt(u16, value, 10),
                    .HOST                 => self.host = try self.allocator.dupe(u8, value),
                }
            }
        }
    }

    pub fn validate(self: *Config) !void {
        if (self.usar_openrouter) {
            if (self.openrouter_api_key.len == 0) return error.MissingOpenRouterApiKey;
        } else {
            if (self.gemini_api_key.len == 0) return error.MissingGeminiApiKey;
        }

        if (self.db_path.len == 0) {
            return error.MissingDbPath;
        }
    }

    pub fn deinit(self: *Config) void {
        if (self.gemini_api_key.len > 0) {
            self.allocator.free(self.gemini_api_key);
        }
        if (self.openrouter_api_key.len > 0) {
            self.allocator.free(self.openrouter_api_key);
        }
        if (self.db_path.len > 0 and !std.mem.eql(u8, self.db_path, "./amelie.db")) {
            self.allocator.free(self.db_path);
        }
        if (self.whatsapp_webhook_url.len > 0 and !std.mem.eql(u8, self.whatsapp_webhook_url, "http://localhost:8080")) {
            self.allocator.free(self.whatsapp_webhook_url);
        }
        if (self.host.len > 0 and !std.mem.eql(u8, self.host, "0.0.0.0")) {
            self.allocator.free(self.host);
        }
    }
};
