# LSP-SDK.zig

Servidor Language Server Protocol (LSP) em Zig v0.17, com transporte stdio e nomes de métodos compatíveis com a especificação LSP 3.18.

Referência da especificação: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/

## O que está incluído

- Executável `lsp-sdk-zig`.
- Framing LSP `Content-Length` sobre stdin/stdout.
- Dispatch com nomes LSP originais, como `initialize`, `shutdown`, `textDocument/completion`, `textDocument/hover`, `textDocument/definition`, `textDocument/documentSymbol` e `workspace/symbol`.
- Otimizações idiomáticas de Zig:
  - tabela de dispatch `comptime` com `std.StaticStringMap`;
  - parsing zero-copy para cabeçalhos, `method` e `id`;
  - buffer estático reutilizável por conexão;
  - respostas pequenas formatadas em stack buffers, sem heap no hot path.

## Uso

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/lsp-sdk-zig
```

## Exemplos

Veja `EXAMPLES.md` para clientes Python/Node.js, integração com Neovim/VS Code e um exemplo específico de IDE para Agents com chat e terminal renderizado no VS Code.

## Testes

```sh
zig build test
```
