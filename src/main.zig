const std = @import("std");

const stdin_fd = 0;
const stdout_fd = 1;
const max_message_bytes = 1024 * 1024;
const read_buffer_bytes = max_message_bytes + 4096;

const Method = enum {
    initialize,
    initialized,
    shutdown,
    exit,
    textDocument_didOpen,
    textDocument_didChange,
    textDocument_didClose,
    textDocument_completion,
    textDocument_hover,
    textDocument_definition,
    textDocument_documentSymbol,
    workspace_symbol,
};

const method_map = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
    .{ "initialized", .initialized },
    .{ "shutdown", .shutdown },
    .{ "exit", .exit },
    .{ "textDocument/didOpen", .textDocument_didOpen },
    .{ "textDocument/didChange", .textDocument_didChange },
    .{ "textDocument/didClose", .textDocument_didClose },
    .{ "textDocument/completion", .textDocument_completion },
    .{ "textDocument/hover", .textDocument_hover },
    .{ "textDocument/definition", .textDocument_definition },
    .{ "textDocument/documentSymbol", .textDocument_documentSymbol },
    .{ "workspace/symbol", .workspace_symbol },
});

pub fn main() !void {
    var server = Server{};
    try server.run();
}

const Message = struct {
    body: []const u8,
    frame_len: usize,
};

const Server = struct {
    buffer: [read_buffer_bytes]u8 = undefined,
    used: usize = 0,
    shutdown_requested: bool = false,

    fn run(self: *Server) !void {
        while (true) {
            if (try self.nextMessage()) |message| {
                try self.handleMessage(message.body);
                self.consume(message.frame_len);
                if (self.shutdown_requested) {
                    // Keep the process alive until the client sends the required `exit` notification.
                }
            } else {
                return;
            }
        }
    }

    fn nextMessage(self: *Server) !?Message {
        while (true) {
            if (findHeaderEnd(self.buffer[0..self.used])) |header_end| {
                const headers = self.buffer[0..header_end];
                const content_length = try parseContentLength(headers);
                if (content_length > max_message_bytes) return error.MessageTooLarge;

                const frame_len = header_end + content_length;
                while (self.used < frame_len) {
                    const n = try std.posix.read(stdin_fd, self.buffer[self.used..]);
                    if (n == 0) return null;
                    self.used += n;
                }

                const body_start = header_end;
                const body_end = frame_len;
                const body = self.buffer[body_start..body_end];

                return .{ .body = body, .frame_len = frame_len };
            }

            if (self.used == self.buffer.len) return error.HeaderTooLarge;
            const n = try std.posix.read(stdin_fd, self.buffer[self.used..]);
            if (n == 0) return null;
            self.used += n;
        }
    }

    fn consume(self: *Server, frame_len: usize) void {
        const trailing = self.used - frame_len;
        if (trailing > 0) {
            @memmove(self.buffer[0..trailing], self.buffer[frame_len..self.used]);
        }
        self.used = trailing;
    }

    fn handleMessage(self: *Server, body: []const u8) !void {
        const method = extractStringField(body, "method") orelse return;
        const maybe_id = extractId(body);

        const known = method_map.get(method);
        if (known) |tag| switch (tag) {
            .initialize => if (maybe_id) |id| try writeResult(id, initialize_result),
            .initialized => {},
            .shutdown => {
                self.shutdown_requested = true;
                if (maybe_id) |id| try writeResult(id, "null");
            },
            .exit => std.process.exit(if (self.shutdown_requested) 0 else 1),
            .textDocument_didOpen,
            .textDocument_didChange,
            .textDocument_didClose,
            => {},
            .textDocument_completion => if (maybe_id) |id| try writeResult(id, completion_result),
            .textDocument_hover => if (maybe_id) |id| try writeResult(id, "null"),
            .textDocument_definition => if (maybe_id) |id| try writeResult(id, "null"),
            .textDocument_documentSymbol => if (maybe_id) |id| try writeResult(id, "[]"),
            .workspace_symbol => if (maybe_id) |id| try writeResult(id, "[]"),
        } else if (maybe_id) |id| {
            try writeError(id, -32601, "Method not found");
        }
    }
};

const initialize_result =
    \\{"capabilities":{"textDocumentSync":2,"completionProvider":{"triggerCharacters":[".",":","@"]},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"workspaceSymbolProvider":true},"serverInfo":{"name":"lsp-sdk-zig","version":"0.1.0"}}
;

const completion_result =
    \\{"isIncomplete":false,"items":[]}
;

fn writeResult(id: []const u8, result_json: []const u8) !void {
    var body: [4096]u8 = undefined;
    const payload = try std.fmt.bufPrint(&body, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result_json });
    try writeFrame(payload);
}

fn writeError(id: []const u8, code: i32, message: []const u8) !void {
    var escaped_buf: [256]u8 = undefined;
    const escaped = escapeJsonString(&escaped_buf, message);

    var body: [1024]u8 = undefined;
    const payload = try std.fmt.bufPrint(&body, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":\"{s}\"}}}}", .{ id, code, escaped });
    try writeFrame(payload);
}

fn writeFrame(payload: []const u8) !void {
    var header: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&header, "Content-Length: {}\r\n\r\n", .{payload.len});
    try writeAll(h);
    try writeAll(payload);
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try std.posix.write(stdout_fd, bytes[offset..]);
        offset += written;
    }
}

fn findHeaderEnd(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and bytes[i + 1] == '\n' and bytes[i + 2] == '\r' and bytes[i + 3] == '\n') return i + 4;
    }
    i = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == '\n' and bytes[i + 1] == '\n') return i + 2;
    }
    return null;
}

fn parseContentLength(headers: []const u8) !usize {
    var it = std.mem.splitScalar(u8, headers, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r \t");
        if (line.len >= "Content-Length:".len and std.ascii.eqlIgnoreCase(line[0.."Content-Length:".len], "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10);
        }
    }
    return error.MissingContentLength;
}

fn extractStringField(json: []const u8, comptime field: []const u8) ?[]const u8 {
    var needle_buf: [field.len + 2]u8 = undefined;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. 1 + field.len], field);
    needle_buf[needle_buf.len - 1] = '"';

    const needle = needle_buf[0..];
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, needle)) |pos| {
        var i = pos + needle.len;
        i = skipWhitespace(json, i);
        if (i >= json.len or json[i] != ':') {
            search_from = pos + 1;
            continue;
        }
        i = skipWhitespace(json, i + 1);
        if (i >= json.len or json[i] != '"') return null;
        return parseJsonStringSlice(json, i);
    }
    return null;
}

fn extractId(json: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, "\"id\"")) |pos| {
        var i = pos + 4;
        i = skipWhitespace(json, i);
        if (i >= json.len or json[i] != ':') {
            search_from = pos + 1;
            continue;
        }
        i = skipWhitespace(json, i + 1);
        if (i >= json.len) return null;
        if (json[i] == '"') return parseJsonStringToken(json, i);

        const start = i;
        while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != '\r' and json[i] != '\n') : (i += 1) {}
        return std.mem.trim(u8, json[start..i], " \t");
    }
    return null;
}

fn parseJsonStringSlice(json: []const u8, quote_index: usize) ?[]const u8 {
    var i = quote_index + 1;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '\\' => i += 1,
            '"' => return json[quote_index + 1 .. i],
            else => {},
        }
    }
    return null;
}

fn parseJsonStringToken(json: []const u8, quote_index: usize) ?[]const u8 {
    if (parseJsonStringSlice(json, quote_index)) |contents| {
        return json[quote_index .. quote_index + contents.len + 2];
    }
    return null;
}

fn skipWhitespace(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len and isWhitespace(bytes[i])) : (i += 1) {}
    return i;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn escapeJsonString(out: []u8, input: []const u8) []const u8 {
    var used: usize = 0;
    for (input) |c| {
        const replacement: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (replacement) |r| {
            if (used + r.len > out.len) break;
            @memcpy(out[used .. used + r.len], r);
            used += r.len;
        } else {
            if (used == out.len) break;
            out[used] = c;
            used += 1;
        }
    }
    return out[0..used];
}

test "parse content length" {
    try std.testing.expectEqual(@as(usize, 42), try parseContentLength("Content-Length: 42\r\n\r\n"));
}

test "extract method and id without allocating" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{}}";
    try std.testing.expectEqualStrings("initialize", extractStringField(body, "method").?);
    try std.testing.expectEqualStrings("7", extractId(body).?);
}

test "find CRLF header boundary" {
    try std.testing.expectEqual(@as(?usize, 21), findHeaderEnd("Content-Length: 2\r\n\r\n{}"));
}
