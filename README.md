# WatchSelfie

Mostra a câmera do iPhone em tela cheia no Apple Watch, com a imagem girada 90°.
Pelo relógio é possível gravar, trocar entre selfie e câmera principal, ajustar o zoom
(Digital Crown ou atalhos) e ver o tempo de gravação.

## Estrutura

- `WatchSelfie/` — app do iPhone: captura da câmera, gravação (AVAssetWriter), ajustes de qualidade, zoom, envio de quadros ao Watch.
- `WatchSelfie Watch App/` — app do Apple Watch: prévia em tela cheia, controles e rotação.
- `WSShared.swift` — comandos e estado trocados entre os dois apps (existe em ambos os targets).

## Requisitos

- Xcode 26 ou mais recente
- iPhone com iOS 17+ e Apple Watch com watchOS 10+ pareado
- Conta Apple (gratuita serve para instalar no próprio aparelho)

## Como rodar

1. Abra `WatchSelfie.xcodeproj`.
2. Em **Signing & Capabilities**, escolha o seu **Team** nos dois targets.
3. Rode no **iPhone físico** com o Watch pareado (o simulador não tem câmera).
4. Abra o app no iPhone e deixe-o aberto. No Watch, toque no aviso do iPhone para abrir a câmera.

## Observações

- A câmera só funciona com o app do iPhone em primeiro plano (restrição do iOS).
- O Watch não consegue abrir o app do iPhone sozinho; por isso o iPhone recebe uma notificação "Toque para abrir".
- A prévia no Watch chega a uns 8–15 quadros por segundo por causa da banda do WatchConnectivity.
