#!/bin/bash
pkg install python3
python -m pip install flask mss pillow
# Configurações
VENV_DIR="venv_screenshare"
SERVER_FILE="server_screenshare.py"
CLOUDFLARED_BIN="./cloudflared"
LOG_FILE="cloudflared.log"
LINK_FILE="link_acesso.txt"
PORT=5000

# Função de Limpeza
cleanup() {
    echo ""
    echo "[INFO] Encerrando processos..."
    kill $SERVER_PID 2>/dev/null
    if [ -f "$CLOUDFLARED_BIN" ]; then
        pkill -P $$ cloudflared 2>/dev/null
    fi
    rm -f "$LOG_FILE"
    echo "[INFO] Tudo encerrado."
    exit
}
trap cleanup SIGINT

echo "=== Setup de Compartilhamento (Salvar Link Local) ==="

# 1. Verificações básicas (Python e Dependências)
if ! command -v python3 &> /dev/null; then
    echo "[ERRO] Python3 necessário."
    exit 1
fi

if [ ! -f "$CLOUDFLARED_BIN" ]; then
    echo "[INFO] Baixando Cloudflared..."
    # Lógica simplificada de download para x86_64 (PC comum)
    pkg install cloudflared -y
fi

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    . "$VENV_DIR/bin/activate"
    pip install -q flask mss pillow
fi

# 2. Gera o Servidor Python (sem logs visíveis)
cat <<EOF > "$SERVER_FILE"
import io, time, logging
from flask import Flask, Response
import mss
from PIL import Image

logging.getLogger('werkzeug').setLevel(logging.ERROR)
app = Flask(__name__)
sct = mss.mss()

def gen_frames():
    try: monitor = sct.monitors[1]
    except: monitor = sct.monitors[0]
    while True:
        sct_img = sct.grab(monitor)
        img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
        frame_buffer = io.BytesIO()
        img.save(frame_buffer, format="JPEG", quality=40)
        yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + frame_buffer.getvalue() + b'\r\n')
        time.sleep(0.1)

@app.route('/')
def video_feed():
    return Response(gen_frames(), mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=$PORT)
EOF

# 3. Inicia processos
echo "[INFO] Iniciando servidor de vídeo..."
. "$VENV_DIR/bin/activate"
python "$SERVER_FILE" &
SERVER_PID=$!
sleep 2

echo "[INFO] Iniciando túnel Cloudflare..."
# Redireciona a saída de erro (onde o link aparece) para um arquivo de log
"$CLOUDFLARED_BIN" tunnel --url http://localhost:$PORT > "$LOG_FILE" 2>&1 &
CF_PID=$!

echo "[INFO] Aguardando geração do link..."

# 4. Loop para extrair o link do arquivo de log
found=0
while [ $found -eq 0 ]; do
    if grep -q "trycloudflare.com" "$LOG_FILE"; then
        # Extrai a URL usando grep e sed
        URL=$(grep -o 'https://[-a-zA-Z0-9]*\.trycloudflare\.com' "$LOG_FILE" | head -n 1)
        
        if [ ! -z "$URL" ]; then
            echo "$URL" > "$LINK_FILE"
            echo ""
            echo "========================================================"
            echo " SUCESSO! Link salvo em: $LINK_FILE"
            echo " Link: $URL"
            echo "========================================================"
            found=1
        fi
    fi
    
    # Se o processo morrer, sai do loop
    if ! kill -0 $CF_PID 2>/dev/null; then
        echo "[ERRO] Cloudflared falhou ao iniciar."
        exit 1
    fi
    sleep 1
done

# Mantém o script rodando
wait $CF_PID
