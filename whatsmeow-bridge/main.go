package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	waProto "go.mau.fi/whatsmeow/binary/proto"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type Config struct {
	Port       string
	AmelieURL  string
	DBPath     string
	BotPhone   string
	MediaDir   string
	BridgeURL  string
}

func configFromEnv() Config {
	return Config{
		Port:      getEnv("BRIDGE_PORT", "8080"),
		AmelieURL: getEnv("AMELIE_URL", "http://localhost:3000"),
		DBPath:    getEnv("BRIDGE_DB_PATH", "db/whatsmeow.db"),
		BotPhone:  getEnv("MOBILE_NUMBER", ""),
		MediaDir:  getEnv("MEDIA_DIR", "./media_tmp"),
		BridgeURL: getEnv("BRIDGE_URL", "http://localhost:8080"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Structs expected by Amélie (Baileys format)
type BaileysWebhook struct {
	Key              BaileysKey      `json:"key"`
	MessageTimestamp int64           `json:"messageTimestamp"`
	PushName         string          `json:"pushName,omitempty"`
	Message          *BaileysMessage `json:"message,omitempty"`
}

type BaileysKey struct {
	RemoteJid   string `json:"remoteJid"`
	FromMe      bool   `json:"fromMe"`
	Id          string `json:"id"`
	Participant string `json:"participant,omitempty"`
}

type BaileysMessage struct {
	Conversation        string               `json:"conversation,omitempty"`
	ExtendedTextMessage *BaileysExtendedText `json:"extendedTextMessage,omitempty"`
	ImageMessage        *BaileysMediaMessage `json:"imageMessage,omitempty"`
	AudioMessage        *BaileysMediaMessage `json:"audioMessage,omitempty"`
	VideoMessage        *BaileysMediaMessage `json:"videoMessage,omitempty"`
	DocumentMessage     *BaileysMediaMessage `json:"documentMessage,omitempty"`
}

type BaileysExtendedText struct {
	Text string `json:"text,omitempty"`
}

type BaileysMediaMessage struct {
	Url      string `json:"url,omitempty"`
	Mimetype string `json:"mimetype,omitempty"`
	Caption  string `json:"caption,omitempty"`
	FileName string `json:"fileName,omitempty"`
}

type SendRequest struct {
	ID     string `json:"id,omitempty"`
	ChatID string `json:"chat_id"`
	Texto  string `json:"texto,omitempty"`
	Reacao string `json:"reacao,omitempty"`
	MsgID  string `json:"msg_id,omitempty"`
}

type AckRequest struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type Bridge struct {
	cfg    Config
	client *whatsmeow.Client
}

func NewBridge(cfg Config) (*Bridge, error) {
	dbLog := waLog.Stdout("Database", "WARN", true)
	container, err := sqlstore.New(context.Background(), "sqlite3", "file:"+cfg.DBPath+"?_foreign_keys=on", dbLog)
	if err != nil {
		return nil, fmt.Errorf("abrindo db: %w", err)
	}

	deviceStore, err := container.GetFirstDevice(context.Background())
	if err != nil {
		return nil, fmt.Errorf("obtendo device: %w", err)
	}

	clientLog := waLog.Stdout("Client", "WARN", true)
	client := whatsmeow.NewClient(deviceStore, clientLog)

	if err := os.MkdirAll(cfg.MediaDir, 0755); err != nil {
		return nil, err
	}

	return &Bridge{cfg: cfg, client: client}, nil
}

func (b *Bridge) Start() error {
	b.client.AddEventHandler(b.handleEvent)

	if b.client.Store.ID == nil {
		if b.cfg.BotPhone != "" {
			return b.loginPairingCode()
		}
		return b.loginQR()
	}

	return b.client.Connect()
}

func (b *Bridge) loginQR() error {
	qrChan, _ := b.client.GetQRChannel(context.Background())
	if err := b.client.Connect(); err != nil {
		return err
	}
	for evt := range qrChan {
		if evt.Event == "code" {
			log.Printf("Novo QR Code gerado. Escaneie no WhatsApp:")
			q, _ := qrcode.New(evt.Code, qrcode.Medium)
			fmt.Println(q.ToSmallString(false))
		} else {
			log.Printf("Auth event: %s\n", evt.Event)
		}
	}
	return nil
}

func (b *Bridge) loginPairingCode() error {
	if err := b.client.Connect(); err != nil {
		return err
	}
	code, err := b.client.PairPhone(context.Background(), b.cfg.BotPhone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return fmt.Errorf("pairing code: %w", err)
	}
	log.Printf("Pairing Code: %s\n", code)
	return nil
}

func (b *Bridge) Stop() {
	b.client.Disconnect()
}

func (b *Bridge) handleEvent(rawEvt interface{}) {
	switch evt := rawEvt.(type) {
	case *events.Message:
		b.processMessage(evt)
	}
}

func (b *Bridge) enviarAck(id string, status string) {
	if id == "" {
		return
	}

	body, err := json.Marshal(AckRequest{ID: id, Status: status})
	if err != nil {
		log.Printf("Erro serializando ack %s: %v", id, err)
		return
	}

	url := fmt.Sprintf("%s/webhook/ack", b.cfg.AmelieURL)
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		log.Printf("Erro enviando ack %s: %v", id, err)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("Ack %s rejeitado com status %d", id, resp.StatusCode)
	}
}

func (b *Bridge) saveMedia(data []byte, ext string) string {
	f, err := os.CreateTemp(b.cfg.MediaDir, "media_*"+ext)
	if err != nil {
		log.Printf("Erro ao salvar media: %v", err)
		return ""
	}
	defer f.Close()
	f.Write(data)
	return filepath.Base(f.Name())
}

func (b *Bridge) processMessage(evt *events.Message) {
	if evt.Info.IsFromMe {
		return
	}

	if evt.Message.GetProtocolMessage() != nil {
		return
	}

	chatID := evt.Info.Chat.String()
	from := evt.Info.Sender.String()
	inGroup := evt.Info.IsGroup
	timestamp := evt.Info.Timestamp.Unix()

	participant := ""
	if inGroup {
		participant = from
	}

	payload := BaileysWebhook{
		Key: BaileysKey{
			RemoteJid:   chatID,
			FromMe:      false,
			Id:          evt.Info.ID,
			Participant: participant,
		},
		MessageTimestamp: timestamp,
		PushName:         evt.Info.PushName,
		Message:          &BaileysMessage{},
	}

	text := extractText(evt.Message)

	if img := evt.Message.GetImageMessage(); img != nil {
		data, err := b.client.Download(context.Background(), img)
		if err == nil {
			filename := b.saveMedia(data, ".jpg")
			payload.Message.ImageMessage = &BaileysMediaMessage{
				Url:      fmt.Sprintf("%s/media/%s", b.cfg.BridgeURL, filename),
				Mimetype: img.GetMimetype(),
				Caption:  img.GetCaption(),
			}
		}
	} else if aud := evt.Message.GetAudioMessage(); aud != nil {
		data, err := b.client.Download(context.Background(), aud)
		if err == nil {
			filename := b.saveMedia(data, ".ogg")
			payload.Message.AudioMessage = &BaileysMediaMessage{
				Url:      fmt.Sprintf("%s/media/%s", b.cfg.BridgeURL, filename),
				Mimetype: aud.GetMimetype(),
			}
		}
	} else if doc := evt.Message.GetDocumentMessage(); doc != nil {
		data, err := b.client.Download(context.Background(), doc)
		if err == nil {
			ext := filepath.Ext(doc.GetFileName())
			if ext == "" {
				ext = ".bin"
			}
			filename := b.saveMedia(data, ext)
			payload.Message.DocumentMessage = &BaileysMediaMessage{
				Url:      fmt.Sprintf("%s/media/%s", b.cfg.BridgeURL, filename),
				Mimetype: doc.GetMimetype(),
				FileName: doc.GetFileName(),
				Caption:  doc.GetCaption(),
			}
		}
	} else if vid := evt.Message.GetVideoMessage(); vid != nil {
		data, err := b.client.Download(context.Background(), vid)
		if err == nil {
			filename := b.saveMedia(data, ".mp4")
			payload.Message.VideoMessage = &BaileysMediaMessage{
				Url:      fmt.Sprintf("%s/media/%s", b.cfg.BridgeURL, filename),
				Mimetype: vid.GetMimetype(),
				Caption:  vid.GetCaption(),
			}
		}
	} else if evt.Message.GetStickerMessage() != nil {
		return // ignore stickers
	} else {
		payload.Message.Conversation = text
	}

	// Se for string vazia e nao tiver midia
	if payload.Message.Conversation == "" && payload.Message.ImageMessage == nil && payload.Message.AudioMessage == nil && payload.Message.VideoMessage == nil && payload.Message.DocumentMessage == nil {
		if text != "" {
			payload.Message.Conversation = text
		} else {
			return
		}
	}

	log.Printf("Repassando mensagem (chat: %s)", chatID)

	data, _ := json.Marshal(payload)
	resp, err := http.Post(b.cfg.AmelieURL, "application/json", bytes.NewReader(data))
	if err != nil {
		log.Printf("Erro webhook: %v\n", err)
	} else {
		io.ReadAll(resp.Body)
		resp.Body.Close()
	}
}

func extractText(msg *waProto.Message) string {
	if msg == nil {
		return ""
	}
	if msg.Conversation != nil {
		return *msg.Conversation
	}
	if msg.ExtendedTextMessage != nil && msg.ExtendedTextMessage.Text != nil {
		return *msg.ExtendedTextMessage.Text
	}
	return ""
}

func (b *Bridge) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	jid, err := types.ParseJID(req.ChatID)
	if err != nil {
		http.Error(w, "invalid chat_id", http.StatusBadRequest)
		return
	}

	var msg *waProto.Message
	if req.Reacao != "" && req.MsgID != "" {
		log.Printf("Reagindo em %s (msg: %s) com %s", req.ChatID, req.MsgID, req.Reacao)
		msg = &waProto.Message{
			ReactionMessage: &waProto.ReactionMessage{
				Key: &waProto.MessageKey{
					RemoteJID: proto.String(req.ChatID),
					FromMe:    proto.Bool(false), // Reagindo a mensagem recebida
					ID:        proto.String(req.MsgID),
				},
				Text:              proto.String(req.Reacao),
				SenderTimestampMS: proto.Int64(time.Now().UnixMilli()),
			},
		}
	} else {
		log.Printf("Enviando para %s: %s", req.ChatID, req.Texto)
		msg = &waProto.Message{
			Conversation: proto.String(req.Texto),
		}
	}

	_, err = b.client.SendMessage(context.Background(), jid, msg)
	if err != nil {
		log.Printf("Erro ao enviar/reagir: %v\n", err)
		http.Error(w, "send failed", http.StatusInternalServerError)
		return
	}

	if req.Reacao == "" {
		b.enviarAck(req.ID, "sent")
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

func main() {
	cfg := configFromEnv()

	bridge, err := NewBridge(cfg)
	if err != nil {
		log.Fatalf("Falha bridge: %v", err)
	}

	if err := bridge.Start(); err != nil {
		log.Fatalf("Falha start: %v", err)
	}
	defer bridge.Stop()

	mux := http.NewServeMux()
	mux.HandleFunc("/send", bridge.handleSend)
	
	// Serve media files
	fs := http.FileServer(http.Dir(cfg.MediaDir))
	mux.Handle("/media/", http.StripPrefix("/media/", fs))

	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: mux,
	}

	go func() {
		log.Printf("Bridge escutando em :%s", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP falhou: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Encerrando...")
	server.Shutdown(context.Background())
}
