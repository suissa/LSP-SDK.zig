# Exemplos de integração

Este documento mostra como outros programas podem acessar o servidor `lsp-sdk-zig`, quais métodos LSP ele entende e para que cada função serve.

O servidor fala LSP por **stdio**: o programa cliente inicia `./zig-out/bin/lsp-sdk-zig`, escreve mensagens JSON-RPC em `stdin` e lê respostas em `stdout`. Cada mensagem precisa usar o framing do LSP:

```text
Content-Length: <tamanho-em-bytes>\r\n\r\n<json-rpc>
```

## Compilando o servidor

```sh
zig build -Doptimize=ReleaseFast
```

O executável esperado fica em:

```sh
./zig-out/bin/lsp-sdk-zig
```

## Para que função serve

Este servidor é uma base mínima para conectar editores, IDEs, CLIs ou ferramentas próprias a um servidor LSP escrito em Zig. Ele já fornece o transporte e o dispatch dos nomes padrão do protocolo, permitindo que outros programas façam chamadas como:

| Método LSP | Tipo | Função no cliente |
| --- | --- | --- |
| `initialize` | request | Negocia capacidades do servidor e recebe `serverInfo`. |
| `initialized` | notification | Avisa que o cliente terminou a inicialização. |
| `shutdown` | request | Solicita encerramento lógico do servidor. |
| `exit` | notification | Encerra o processo após `shutdown`. |
| `textDocument/didOpen` | notification | Informa que um documento foi aberto. |
| `textDocument/didChange` | notification | Informa alterações de texto. |
| `textDocument/didClose` | notification | Informa que um documento foi fechado. |
| `textDocument/completion` | request | Solicita sugestões de autocomplete. Atualmente retorna lista vazia. |
| `textDocument/hover` | request | Solicita informações de hover. Atualmente retorna `null`. |
| `textDocument/definition` | request | Solicita localização de definição. Atualmente retorna `null`. |
| `textDocument/documentSymbol` | request | Solicita símbolos do documento. Atualmente retorna lista vazia. |
| `workspace/symbol` | request | Solicita símbolos do workspace. Atualmente retorna lista vazia. |

## Exemplo 1: cliente Python direto por stdio

Este exemplo inicia o servidor, envia `initialize`, lê uma resposta LSP e encerra com `shutdown` + `exit`.

```python
#!/usr/bin/env python3
import json
import subprocess

server = subprocess.Popen(
    ["./zig-out/bin/lsp-sdk-zig"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

def send(message: dict) -> None:
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    server.stdin.write(header + body)
    server.stdin.flush()

def read() -> dict:
    headers = b""
    while b"\r\n\r\n" not in headers:
        headers += server.stdout.read(1)

    length = None
    for line in headers.decode("ascii").split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())

    if length is None:
        raise RuntimeError("resposta sem Content-Length")

    return json.loads(server.stdout.read(length).decode("utf-8"))

send({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "processId": None,
        "rootUri": None,
        "capabilities": {},
    },
})
print(read())

send({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
print(read())

send({"jsonrpc": "2.0", "method": "exit"})
server.wait(timeout=2)
```

Use esse padrão quando você quiser testar o servidor sem editor, escrever um cliente customizado ou integrar o LSP a uma ferramenta de linha de comando.

## Exemplo 2: cliente Node.js direto por stdio

```js
import { spawn } from "node:child_process";

const server = spawn("./zig-out/bin/lsp-sdk-zig", [], {
  stdio: ["pipe", "pipe", "inherit"],
});

let buffer = Buffer.alloc(0);

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii");
  server.stdin.write(Buffer.concat([header, body]));
}

server.stdout.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);

  const headerEnd = buffer.indexOf("\r\n\r\n");
  if (headerEnd === -1) return;

  const header = buffer.subarray(0, headerEnd).toString("ascii");
  const match = header.match(/content-length:\s*(\d+)/i);
  if (!match) throw new Error("resposta sem Content-Length");

  const length = Number(match[1]);
  const bodyStart = headerEnd + 4;
  const bodyEnd = bodyStart + length;
  if (buffer.length < bodyEnd) return;

  const body = buffer.subarray(bodyStart, bodyEnd).toString("utf8");
  console.log(JSON.parse(body));
  buffer = buffer.subarray(bodyEnd);
});

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { processId: null, rootUri: null, capabilities: {} },
});
```

Use esse padrão quando o cliente for uma extensão, daemon, aplicação Electron ou ferramenta JavaScript/TypeScript.

## Exemplo 3: Neovim

Em Neovim, um cliente LSP pode iniciar o binário por `cmd` e anexar buffers ao servidor.

```lua
vim.lsp.start({
  name = "lsp-sdk-zig",
  cmd = { "./zig-out/bin/lsp-sdk-zig" },
  root_dir = vim.fn.getcwd(),
})
```

Depois de iniciado, o Neovim envia `initialize`, `initialized`, notificações `textDocument/*` e requests como `textDocument/completion` conforme os recursos configurados no editor.

## Exemplo 4: VS Code

Uma extensão VS Code pode acessar o servidor com `LanguageClient` usando transporte stdio.

```ts
import * as vscode from "vscode";
import { LanguageClient, ServerOptions, TransportKind } from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
  const serverOptions: ServerOptions = {
    command: context.asAbsolutePath("zig-out/bin/lsp-sdk-zig"),
    transport: TransportKind.stdio,
  };

  client = new LanguageClient(
    "lsp-sdk-zig",
    "LSP SDK Zig",
    serverOptions,
    { documentSelector: [{ scheme: "file" }] },
  );

  context.subscriptions.push(client.start());
}

export function deactivate() {
  return client?.stop();
}
```

Use esse padrão quando quiser publicar o servidor como backend de uma extensão do VS Code.

## Exemplo 5: sequência mínima de mensagens

Uma sessão LSP típica começa assim:

1. Cliente envia `initialize`.
2. Servidor responde com capacidades.
3. Cliente envia `initialized`.
4. Cliente envia notificações de documento, como `textDocument/didOpen`.
5. Cliente envia requests, como `textDocument/completion`.
6. Cliente envia `shutdown`.
7. Cliente envia `exit`.

Exemplo do JSON de `initialize`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "processId": null,
    "rootUri": null,
    "capabilities": {}
  }
}
```

Exemplo do JSON de completion:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "textDocument/completion",
  "params": {
    "textDocument": { "uri": "file:///tmp/example.zig" },
    "position": { "line": 0, "character": 0 }
  }
}
```


## Exemplo 6: VS Code como IDE para Agents com chat e terminal renderizado

Um uso mais específico é transformar o servidor `lsp-sdk-zig` no backend de uma IDE para **Agents**. Nesse modelo, o VS Code continua sendo o ambiente principal de edição, enquanto a extensão renderiza uma conversa de chat e um terminal associado ao Agent. Assim, quem já usa IDE pode migrar para um fluxo com Agents sem perder editor, atalhos, abas, diagnósticos, navegação por arquivos ou terminal integrado.

A arquitetura recomendada fica assim:

1. A extensão VS Code inicia o servidor LSP `lsp-sdk-zig` por stdio.
2. O VS Code usa o LSP para recursos de editor, como completion, hover, definição e símbolos.
3. A extensão cria uma `WebviewView` ou `WebviewPanel` para a conversa com o Agent.
4. A extensão cria um `Terminal` dedicado para mostrar comandos, logs e saídas produzidas pelo Agent.
5. O chat envia intenções do usuário para a extensão, e a extensão decide se deve chamar comandos VS Code, requests LSP, ou escrever no terminal.

### Exemplo 6.1: estrutura de uma extensão VS Code

```text
agent-ide-extension/
├── package.json
├── src/
│   ├── extension.ts
│   ├── lspClient.ts
│   ├── agentChatView.ts
│   └── agentTerminal.ts
└── zig-out/bin/lsp-sdk-zig
```

Essa divisão mantém responsabilidades separadas:

| Arquivo | Responsabilidade |
| --- | --- |
| `extension.ts` | Ativa a extensão e registra comandos/views. |
| `lspClient.ts` | Inicia o `LanguageClient` que conversa com `lsp-sdk-zig`. |
| `agentChatView.ts` | Renderiza o chat do Agent em Webview. |
| `agentTerminal.ts` | Cria e controla o terminal integrado do Agent. |

### Exemplo 6.2: `package.json` com comandos e view de chat

```json
{
  "name": "agent-ide",
  "displayName": "Agent IDE",
  "engines": { "vscode": "^1.90.0" },
  "activationEvents": [
    "onView:agentIde.chat",
    "onCommand:agentIde.openChat",
    "onCommand:agentIde.runInTerminal"
  ],
  "contributes": {
    "commands": [
      {
        "command": "agentIde.openChat",
        "title": "Agent IDE: Abrir Chat"
      },
      {
        "command": "agentIde.runInTerminal",
        "title": "Agent IDE: Executar no Terminal do Agent"
      }
    ],
    "viewsContainers": {
      "activitybar": [
        {
          "id": "agentIde",
          "title": "Agents",
          "icon": "resources/agent.svg"
        }
      ]
    },
    "views": {
      "agentIde": [
        {
          "id": "agentIde.chat",
          "name": "Chat do Agent"
        }
      ]
    }
  },
  "dependencies": {
    "vscode-languageclient": "^9.0.1"
  },
  "devDependencies": {
    "@types/vscode": "^1.90.0",
    "typescript": "^5.0.0"
  }
}
```

### Exemplo 6.3: iniciar o servidor LSP e registrar o chat

```ts
// src/extension.ts
import * as vscode from "vscode";
import { startLspClient } from "./lspClient";
import { AgentChatViewProvider } from "./agentChatView";
import { AgentTerminal } from "./agentTerminal";

export async function activate(context: vscode.ExtensionContext) {
  const terminal = new AgentTerminal("Agent Terminal");
  const client = startLspClient(context);

  const chatProvider = new AgentChatViewProvider(context.extensionUri, terminal, client);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider("agentIde.chat", chatProvider),
    vscode.commands.registerCommand("agentIde.openChat", async () => {
      await vscode.commands.executeCommand("agentIde.chat.focus");
    }),
    vscode.commands.registerCommand("agentIde.runInTerminal", async () => {
      const command = await vscode.window.showInputBox({
        prompt: "Comando para executar no terminal do Agent",
        placeHolder: "zig build test",
      });
      if (command) terminal.send(command);
    }),
    client,
    terminal,
  );

  await client.start();
}
```

### Exemplo 6.4: cliente LSP para o `lsp-sdk-zig`

```ts
// src/lspClient.ts
import * as vscode from "vscode";
import { LanguageClient, ServerOptions, TransportKind } from "vscode-languageclient/node";

export function startLspClient(context: vscode.ExtensionContext): LanguageClient {
  const command = context.asAbsolutePath("zig-out/bin/lsp-sdk-zig");

  const serverOptions: ServerOptions = {
    command,
    transport: TransportKind.stdio,
  };

  return new LanguageClient(
    "lsp-sdk-zig",
    "LSP SDK Zig",
    serverOptions,
    {
      documentSelector: [
        { scheme: "file", language: "zig" },
        { scheme: "file", language: "plaintext" }
      ],
      synchronize: {
        fileEvents: vscode.workspace.createFileSystemWatcher("**/*"),
      },
    },
  );
}
```

Nesse ponto, o servidor Zig recebe requests padrão do VS Code, como `initialize`, `textDocument/didOpen`, `textDocument/didChange`, `textDocument/completion` e `textDocument/hover`.

### Exemplo 6.5: terminal renderizado para o Agent

```ts
// src/agentTerminal.ts
import * as vscode from "vscode";

export class AgentTerminal implements vscode.Disposable {
  private readonly terminal: vscode.Terminal;

  constructor(name: string) {
    this.terminal = vscode.window.createTerminal({ name });
  }

  show() {
    this.terminal.show(true);
  }

  send(command: string) {
    this.terminal.show(true);
    this.terminal.sendText(command, true);
  }

  dispose() {
    this.terminal.dispose();
  }
}
```

Esse terminal é útil para mostrar ações que o Agent está executando: builds, testes, comandos de inspeção, logs e scripts. Para o usuário, a experiência continua parecida com o terminal integrado que ele já conhece no VS Code.

### Exemplo 6.6: Webview de chat que conversa com a extensão

```ts
// src/agentChatView.ts
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";
import { AgentTerminal } from "./agentTerminal";

export class AgentChatViewProvider implements vscode.WebviewViewProvider {
  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly terminal: AgentTerminal,
    private readonly client: LanguageClient,
  ) {}

  resolveWebviewView(view: vscode.WebviewView) {
    view.webview.options = { enableScripts: true };
    view.webview.html = this.renderHtml();

    view.webview.onDidReceiveMessage(async (message) => {
      if (message.type === "runCommand") {
        this.terminal.send(message.command);
        await view.webview.postMessage({
          type: "agentMessage",
          text: `Executando no terminal: ${message.command}`,
        });
      }

      if (message.type === "askCompletion") {
        const editor = vscode.window.activeTextEditor;
        if (!editor) return;

        const result = await this.client.sendRequest("textDocument/completion", {
          textDocument: { uri: editor.document.uri.toString() },
          position: {
            line: editor.selection.active.line,
            character: editor.selection.active.character,
          },
        });

        await view.webview.postMessage({
          type: "agentMessage",
          text: `Completion retornou: ${JSON.stringify(result)}`,
        });
      }
    });
  }

  private renderHtml(): string {
    return /* html */ `
      <!doctype html>
      <html lang="pt-BR">
      <body>
        <h2>Agent IDE</h2>
        <div id="messages"></div>
        <input id="prompt" placeholder="Peça algo ao Agent, ex: rodar testes" />
        <button id="send">Enviar</button>
        <button id="completion">Pedir completion LSP</button>

        <script>
          const vscode = acquireVsCodeApi();
          const messages = document.getElementById('messages');
          const prompt = document.getElementById('prompt');

          document.getElementById('send').addEventListener('click', () => {
            vscode.postMessage({ type: 'runCommand', command: prompt.value });
          });

          document.getElementById('completion').addEventListener('click', () => {
            vscode.postMessage({ type: 'askCompletion' });
          });

          window.addEventListener('message', (event) => {
            const p = document.createElement('p');
            p.textContent = event.data.text;
            messages.appendChild(p);
          });
        </script>
      </body>
      </html>
    `;
  }
}
```

Esse exemplo mostra o fluxo principal para uma IDE baseada em Agents:

- O usuário escreve no chat.
- A Webview envia a intenção para a extensão.
- A extensão pode executar comandos no terminal integrado.
- A extensão pode consultar o servidor LSP para obter contexto do editor.
- O resultado volta para o chat sem tirar o usuário da IDE.

### Exemplo 6.7: mapeando intenções do chat para ações de IDE

| Intenção no chat | Ação da extensão | Interação com o servidor |
| --- | --- | --- |
| "Explique este arquivo" | Lê o editor ativo e mostra resposta no chat. | Pode usar símbolos via `textDocument/documentSymbol`. |
| "Complete aqui" | Pega posição do cursor e pede completion. | Chama `textDocument/completion`. |
| "Onde isso é definido?" | Usa a posição do cursor. | Chama `textDocument/definition`. |
| "Rode os testes" | Envia `zig build test` ao terminal do Agent. | Não precisa de LSP. |
| "Mostre símbolos do workspace" | Exibe uma lista no chat ou QuickPick. | Chama `workspace/symbol`. |

Com essa abordagem, o chat não substitui a IDE: ele vira uma camada de interação acima do editor, do LSP e do terminal. Isso reduz atrito para quem já trabalha no VS Code, porque os comandos do Agent aparecem no terminal integrado e os resultados podem ser renderizados no chat da própria IDE.

## Observações importantes

- O servidor atual é uma base de SDK: ele expõe o protocolo e respostas mínimas, mas ainda não implementa análise semântica real de uma linguagem.
- As funções de completion, hover, definition e symbols estão prontas para serem preenchidas com lógica específica do domínio.
- Requests precisam ter `id`; notifications não devem esperar resposta.
- O framing `Content-Length` conta bytes UTF-8 do corpo JSON, não quantidade de caracteres.
