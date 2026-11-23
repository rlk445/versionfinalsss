# Metulas iOS (cenário + menu flutuante + rastreamento de mãos MediaPipe + modo VR)

Port dos 7 ambientes do app Quest (desert, winterlodge, bubbles, ryokan, dome, spacestation, cybercity) para iPhone/iPad (Metal). As mãos vêm da câmera
frontal via MediaPipe Hand Landmarker (21 pontos por mão).

## Como gerar o IPA
1. Crie um repositório no GitHub e envie TODO o conteúdo desta pasta
   (código + todas as pastas de `Resources/`: desert, winterlodge, bubbles, ryokan, dome, spacestation, cybercity, sfx, browser), mantendo a estrutura.
2. Aba **Actions** > workflow **Build IPA** > **Run workflow** (ou faça um push).
3. Ao terminar, baixe o artifact **Metulas-ipa-build-N** (`Metulas-build-N.ipa`). O canto superior do app mostra `v3 #N`: se N bater com o número da execução no GitHub, você está com o build certo.
4. O IPA sai **sem assinatura**. Instale com AltStore, Sideloadly ou outro assinador
   usando seu Apple ID.

O modelo `hand_landmarker.task` é baixado automaticamente pelo workflow.

## Controles
- Giroscópio gira a câmera. Arrastar o dedo na tela também gira.
- Pinça (polegar + indicador) na frente da câmera e arraste: gira a cena.
- Botão redondo (embaixo): abre o menu. Com o menu aberto, o cursor branco segue sua mão;
  **pinçar em cima de um botão = clicar**. Pinçar e arrastar sobre um controle deslizante ajusta o valor,
  e sobre uma área vazia de uma lista rola a página. A barrinha embaixo do dock move o menu.
- No navegador, pinçar na página = clicar; pinçar e arrastar = rolar. Ao clicar num campo de texto o teclado virtual abre sozinho.
- Tudo no menu também funciona por toque na tela.

## Mãos translúcidas, escolha da câmera e modo VR (novo)
- **Mão estilo Quest**: o esqueleto de linhas foi trocado por uma silhueta branca translúcida (contorno fino, preenchimento
  suave, brilho nas bordas e antebraço que some). Ela é desenhada pelo shader `handsdf_*` (`Shaders.metal`) a partir dos
  21 pontos do MediaPipe, e acompanha o tamanho real da sua mão.
- **Câmera do rastreamento**: Configurações > Mãos e Controles > *Câmera do rastreamento*. Escolha entre traseira principal (1x),
  ultra-angular (0,5x), teleobjetiva e frontal (só aparecem as que o aparelho tem). A escolha vale também para o Passthrough
  e fica salva.
- **Modo VR (VR Box / Shinecon)**: botão **Entrar no modo VR** no canto superior esquerdo, em Configurações rápidas (Modo VR) e
  em Mãos e Controles. A tela gira para paisagem e é dividida em dois olhos (cena em estéreo, menu e mãos nos dois lados).
  Ao entrar, se a câmera estiver na frontal ela troca sozinha para a traseira principal; ao sair, volta para a anterior.
  Dentro do VR: *Sair do VR* no topo do menu, *Inverter orientação* (se a imagem ficar de cabeça para baixo) e
  *Separação das imagens* (ajusta a distância entre as duas imagens para casar com as lentes).
- Coloque o celular no VR Box com a câmera traseira livre (sem tampa na frente) e mantenha as mãos à frente do celular.

## Dock
Hora/bateria/Wi-Fi (Configurações rápidas) | Navegador | Arquivos | Capturar | Ambientes | Configurações | Fechar.

## O que foi portado do Shell.java / classes do Quest
- **Menu e Configurações**: Sistema, Personalização (ambiente e tema), Mãos e Controles, Acessibilidade, Armazenamento, Sobre.
- **Navegador** (`Browser.java`): guias, barra de endereço (pesquisa no Google se não for um endereço), voltar/avançar/recarregar,
  favoritos, histórico, zoom, visualização em teatro, limpar dados, downloads (vão para Arquivos > Downloads),
  página "Nova guia" (`browser/newtab.html` do original).
- **Teclado virtual**: letras, símbolos, símbolos 2, emojis, shift/caps, teclas de URL (`/` e `.com`). Digita na barra de endereço,
  no nome do perfil e nos campos de texto das páginas.
- **Arquivos e visualizador** (`Media.java`): capturas, importados do álbum e downloads; fotos e vídeos abrem no visualizador
  (anterior/próximo, play/pausa, barra de tempo, compartilhar, excluir). Os arquivos ficam em Documents/ e aparecem no app Arquivos do iPhone.
- **Compartilhar / Capturar** (`Capture.java`): foto da cena com contagem de 3 s (sem o menu na imagem) e gravação de vídeo da tela (ReplayKit).
- **Notificações**: lista dos avisos do próprio app (foto salva, download concluído, gravação salva).
- **Perfil**: nome (teclado virtual) e foto (álbum), usados no avatar do menu rápido.
- **Abertura e boas-vindas**: tela de boot com o som `startup` e cartão "Bem-vindo ao Metulas" na primeira vez.
- **Sons**: todos os `.ogg`/`.wav` do original convertidos para `.m4a` em `Resources/sfx` (teclado, UI, câmera, notificação, etc.).
- `scene.bin` (formato V40S v2), texturas KTX/ASTC e `ambient` do ambiente `desert`.

## Adicionado nesta versão (equivalentes iOS dos itens do Quest)
- **Animação das palmeiras** (e dos demais nós animados): o `scene.bin` traz skins (juntas + bind inversa) e canais de animação
  (translação/rotação, loop de ~8,2 s). O app agora lê isso e deforma as malhas na CPU (4 juntas por vértice, `Animation.swift`).
  No instante 0 o resultado é idêntico à pose de repouso; o balanço é suave.
- **Passthrough** (Configurações rápidas e Mãos e Controles): troca o ambiente pela câmera frontal (a mesma usada nas mãos).
- **Controles** (GameController): controle Xbox/PlayStation/MFi aparece em Mãos e Controles com bateria; analógico direito gira a vista,
  Menu abre/fecha o menu, B volta, Y centraliza.
- **Apps** (novo item no dock): biblioteca com atalhos para Loja (App Store), Explorar (navegador), Pessoas (FaceTime), Mensagens,
  Mapas, Música, Fotos, Arquivos e E-mail, mais os favoritos do navegador como "apps da web".
- **Transmitir (Cast)**: mostra se a tela está sendo transmitida; o espelhamento em si só pode ser iniciado pela Central de Controle do iOS.

## O que NÃO dá para portar para o iPhone
- Guardian/Limite, Roomscale/Stationary e Air Link: dependem do rastreamento de posição e do PC link do Quest.
- Lista de apps instalados/em execução, Fontes desconhecidas e Permissões de outros apps, iniciar com o headset e
  ler notificações de outros apps: o iOS não expõe essas APIs.
- Skins visuais do shell: ficam no código nativo do Quest (`libv40shell.so`, sem fonte).
- Ambientes: por enquanto só o `desert`, como combinado. Para incluir outro, coloque a pasta em `Resources/<id>/` (o `project.yml` já aceita).

## Observação
Este código foi escrito sem um compilador Swift/Xcode disponível. A primeira execução do workflow **Build IPA** é o teste de compilação;
se der erro, mande o log do Actions.
