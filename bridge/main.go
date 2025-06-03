package main

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/HugoSmits86/nativewebp"
	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	xwebp "golang.org/x/image/webp"
	"google.golang.org/protobuf/proto"
)

type outEvent map[string]any

type command struct {
	Cmd          string   `json:"cmd"`
	Chat         string   `json:"chat"`
	Text         string   `json:"text"`
	TempID       string   `json:"tempId"`
	IDs          []string `json:"ids"`
	Sender       string   `json:"sender"`
	PictureID    string   `json:"pictureId"`
	Value        bool     `json:"value"`
	Duration     int64    `json:"duration"`
	ID           string   `json:"id"`
	Timestamp    int64    `json:"timestamp"`
	FromMe       bool     `json:"fromMe"`
	Path         string   `json:"path"`
	Kind         string   `json:"kind"`
	FileName     string   `json:"fileName"`
	Mime         string   `json:"mime"`
	Thumb        []byte   `json:"thumb"`
	Width        uint32   `json:"width"`
	Height       uint32   `json:"height"`
	Seconds      uint32   `json:"seconds"`
	Waveform     []byte   `json:"waveform"`
	QuotedID     string   `json:"quotedId"`
	QuotedSender string   `json:"quotedSender"`
	QuotedText   string   `json:"quotedText"`
	QuotedFromMe bool     `json:"quotedFromMe"`
}

type bridge struct {
	client     *whatsmeow.Client
	outMu      sync.Mutex
	names      sync.Map
	ctx        context.Context
	selfUser   string
	avatarDir  string
	avatarSlot chan struct{}
	mediaDir   string
	mediaSlot  chan struct{}
	db         *sql.DB
	blockMu    sync.Mutex
	blockHash  string
}

func (b *bridge) emitSetting(raw types.JID, key string, value bool) {
	jid := b.canonical(raw)
	if ignored(jid) {
		return
	}
	if value {
		b.resolveName(jid, "")
	}
	b.emit(outEvent{"type": "settings", "jid": jid.String(), key: value})
}

func (b *bridge) deleteChat(cmd command) {
	parsed, err := types.ParseJID(cmd.Chat)
	if err != nil {
		return
	}
	if err := b.client.SendAppState(b.ctx, appstate.BuildDeleteChat(b.altJID(parsed), time.Time{}, nil, true)); err != nil {
		b.fail("delete", err)
	}
}

func (b *bridge) resyncLocks() {
	flag := filepath.Join(filepath.Dir(b.avatarDir), "lock-sync-v1")
	if _, err := os.Stat(flag); err == nil {
		return
	}
	for _, name := range appstate.AllPatchNames {
		if err := b.client.FetchAppState(b.ctx, name, true, false); err != nil {
			return
		}
	}
	os.WriteFile(flag, []byte("ok"), 0o644)
}

func (b *bridge) emitBlocklist(list *types.Blocklist) {
	if list == nil {
		return
	}
	b.blockMu.Lock()
	b.blockHash = list.DHash
	b.blockMu.Unlock()
	ids := []string{}
	for _, item := range list.Items {
		if !item.PN.IsEmpty() {
			ids = append(ids, item.PN.ToNonAD().String())
		}
		if !item.LID.IsEmpty() {
			ids = append(ids, b.canonical(item.LID).String(), item.LID.ToNonAD().String())
		}
	}
	b.emit(outEvent{"type": "blocklist", "ids": ids})
}

func (b *bridge) refreshBlocklist() {
	list, err := b.client.GetBlocklist(b.ctx, "")
	if err == nil {
		b.emitBlocklist(list)
	}
}

func (b *bridge) block(cmd command) {
	jid, err := types.ParseJID(cmd.Chat)
	if err != nil || jid.Server == types.GroupServer {
		return
	}
	action := events.BlocklistChangeActionUnblock
	if cmd.Value {
		action = events.BlocklistChangeActionBlock
	}
	b.blockMu.Lock()
	hash := b.blockHash
	b.blockMu.Unlock()
	list, err := b.client.UpdateBlocklist(b.ctx, jid, action, hash)
	if err != nil {
		b.fail("block", err)
		b.refreshBlocklist()
		return
	}
	b.emitBlocklist(list)
}

func (b *bridge) altJID(jid types.JID) types.JID {
	if jid.Server == types.DefaultUserServer {
		if lid, err := b.client.Store.LIDs.GetLIDForPN(b.ctx, jid); err == nil && !lid.IsEmpty() {
			return lid.ToNonAD()
		}
	}
	return jid
}

func isMuted(until time.Time) bool {
	return !until.IsZero() && (until.Unix() < 0 || until.After(time.Now()))
}

func (b *bridge) emitSettings(jid types.JID) {
	archived, pinned, muted, found := false, false, false, false
	for _, candidate := range []types.JID{jid, b.altJID(jid)} {
		settings, err := b.client.Store.ChatSettings.GetChatSettings(b.ctx, candidate)
		if err != nil || !settings.Found {
			continue
		}
		found = true
		archived = archived || settings.Archived
		pinned = pinned || settings.Pinned
		muted = muted || isMuted(settings.MutedUntil)
	}
	if !found {
		return
	}
	b.emit(outEvent{"type": "settings", "jid": jid.String(), "archived": archived, "pinned": pinned, "muted": muted})
}

func (b *bridge) syncAllSettings() {
	if b.db == nil {
		return
	}
	rows, err := b.db.QueryContext(b.ctx, "SELECT DISTINCT chat_jid FROM whatsmeow_chat_settings WHERE archived OR pinned OR muted_until <> 0")
	if err != nil {
		return
	}
	var jids []string
	for rows.Next() {
		var raw string
		if rows.Scan(&raw) == nil {
			jids = append(jids, raw)
		}
	}
	rows.Close()
	for _, raw := range jids {
		parsed, err := types.ParseJID(raw)
		if err != nil {
			continue
		}
		jid := b.canonical(parsed)
		if ignored(jid) {
			continue
		}
		b.resolveName(jid, "")
		b.emitSettings(jid)
	}
}

func (b *bridge) changeSetting(cmd command) {
	parsed, err := types.ParseJID(cmd.Chat)
	if err != nil {
		return
	}
	target := b.altJID(parsed)
	var patch appstate.PatchInfo
	switch cmd.Cmd {
	case "archive":
		patch = appstate.BuildArchive(target, cmd.Value, time.Time{}, nil)
	case "pin":
		patch = appstate.BuildPin(target, cmd.Value)
	case "mute":
		patch = appstate.BuildMute(target, cmd.Value, time.Duration(cmd.Duration)*time.Second)
	case "read":
		patch = appstate.BuildMarkChatAsRead(target, cmd.Value, time.Time{}, nil)
	default:
		return
	}
	if err := b.client.SendAppState(b.ctx, patch); err != nil {
		b.fail(cmd.Cmd, err)
		b.emitSettings(b.canonical(parsed))
	}
}

type mediaInfo struct {
	kind     string
	caption  string
	thumb    []byte
	download whatsmeow.DownloadableMessage
	ext      string
	fileName string
	size     uint64
	seconds  uint32
	waveform []byte
	ptt      bool
}

func mediaOf(m *waE2E.Message) *mediaInfo {
	if m == nil {
		return nil
	}
	switch {
	case m.GetImageMessage() != nil:
		img := m.GetImageMessage()
		return &mediaInfo{kind: "image", caption: img.GetCaption(), thumb: img.GetJPEGThumbnail(), download: img, ext: ".jpg"}
	case m.GetStickerMessage() != nil:
		return &mediaInfo{kind: "sticker", download: m.GetStickerMessage(), ext: ".webp"}
	case m.GetDocumentMessage() != nil:
		doc := m.GetDocumentMessage()
		ext := filepath.Ext(doc.GetFileName())
		if ext == "" {
			ext = ".bin"
		}
		return &mediaInfo{kind: "document", caption: doc.GetCaption(), download: doc, ext: ext, fileName: doc.GetFileName(), size: doc.GetFileLength()}
	case m.GetAudioMessage() != nil:
		audio := m.GetAudioMessage()
		ext := ".ogg"
		if mime := audio.GetMimetype(); mime != "" && !strings.Contains(mime, "ogg") {
			ext = map[string]string{"audio/mp4": ".m4a", "audio/mpeg": ".mp3", "audio/aac": ".aac", "audio/amr": ".amr"}[strings.Split(mime, ";")[0]]
			if ext == "" {
				ext = ".m4a"
			}
		}
		return &mediaInfo{kind: "audio", download: audio, ext: ext, size: audio.GetFileLength(), seconds: audio.GetSeconds(), waveform: audio.GetWaveform(), ptt: audio.GetPTT()}
	case m.GetDocumentWithCaptionMessage() != nil:
		return mediaOf(m.GetDocumentWithCaptionMessage().GetMessage())
	case m.GetEphemeralMessage() != nil:
		return mediaOf(m.GetEphemeralMessage().GetMessage())
	case m.GetViewOnceMessage() != nil:
		return mediaOf(m.GetViewOnceMessage().GetMessage())
	}
	return nil
}

func safeName(parts ...string) string {
	name := strings.Join(parts, "_")
	return strings.Map(func(r rune) rune {
		if r == '/' || r == ':' || r == '\\' {
			return '-'
		}
		return r
	}, name)
}

func writeFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".media-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	tmp.Close()
	return os.Rename(tmp.Name(), path)
}

func (b *bridge) prepareMedia(chat types.JID, id string, media *mediaInfo, history bool) string {
	base := filepath.Join(b.mediaDir, safeName(chat.String(), id))
	full := base + media.ext
	if _, err := os.Stat(full); err == nil {
		return full
	}
	if media.kind == "document" && (history || media.size > 25*1024*1024) {
		return ""
	}
	if media.kind == "audio" && media.size > 16*1024*1024 {
		return ""
	}
	go b.downloadMedia(chat, id, full, media)
	if len(media.thumb) > 0 {
		thumb := base + "-thumb.jpg"
		if writeFile(thumb, media.thumb) == nil {
			return thumb
		}
	}
	return ""
}

func (b *bridge) downloadMedia(chat types.JID, id, path string, media *mediaInfo) {
	b.mediaSlot <- struct{}{}
	defer func() { <-b.mediaSlot }()
	ctx, cancel := context.WithTimeout(b.ctx, 2*time.Minute)
	defer cancel()
	data, err := b.client.Download(ctx, media.download)
	if err != nil || writeFile(path, data) != nil {
		return
	}
	b.emit(outEvent{"type": "media", "chat": chat.String(), "id": id, "path": path})
}

func (b *bridge) emit(e outEvent) {
	data, err := json.Marshal(e)
	if err != nil {
		return
	}
	b.outMu.Lock()
	defer b.outMu.Unlock()
	os.Stdout.Write(append(data, '\n'))
}

func (b *bridge) fail(context string, err error) {
	b.emit(outEvent{"type": "error", "message": fmt.Sprintf("%s: %v", context, err)})
}

func (b *bridge) canonical(jid types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server == types.HiddenUserServer {
		if pn, err := b.client.Store.LIDs.GetPNForLID(b.ctx, jid); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return jid
}

func ignored(jid types.JID) bool {
	return jid.Server == types.BroadcastServer || jid.Server == types.NewsletterServer || jid.IsEmpty()
}

func (b *bridge) contactName(jid types.JID) string {
	info, err := b.client.Store.Contacts.GetContact(b.ctx, jid)
	if err == nil && info.Found {
		for _, n := range []string{info.FullName, info.FirstName, info.PushName, info.BusinessName} {
			if n != "" {
				return n
			}
		}
	}
	if jid.Server == types.DefaultUserServer {
		return "+" + jid.User
	}
	return jid.User
}

func (b *bridge) resolveName(jid types.JID, hint string) {
	if _, done := b.names.LoadOrStore(jid.String(), true); done {
		return
	}
	go b.emitName(jid, hint)
}

func (b *bridge) emitName(jid types.JID, hint string) {
	isGroup := jid.Server == types.GroupServer
	name := ""
	if isGroup {
		if info, err := b.client.GetGroupInfo(b.ctx, jid); err == nil {
			name = info.Name
		}
	} else if contact := b.contactName(jid); contact != "+"+jid.User && contact != jid.User {
		name = contact
	}
	if name == "" {
		name = hint
	}
	fallback := name == ""
	if fallback {
		name = b.contactName(jid)
	}
	b.emit(outEvent{"type": "chat", "jid": jid.String(), "name": name, "isGroup": isGroup, "fallback": fallback})
}

func (b *bridge) memberName(jid types.JID, pushName string) string {
	info, err := b.client.Store.Contacts.GetContact(b.ctx, jid)
	if err == nil && info.Found {
		for _, n := range []string{info.FullName, info.FirstName} {
			if n != "" {
				return n
			}
		}
		if pushName == "" {
			pushName = info.PushName
		}
	}
	if pushName != "" {
		return "~" + pushName
	}
	if jid.Server == types.DefaultUserServer {
		return "+" + jid.User
	}
	return jid.User
}

func (b *bridge) emitMembers(raw string) {
	jid, err := types.ParseJID(raw)
	if err != nil || jid.Server != types.GroupServer {
		return
	}
	info, err := b.client.GetGroupInfo(b.ctx, jid)
	if err != nil {
		return
	}
	names := []string{}
	isSelf := false
	for _, p := range info.Participants {
		member := b.canonical(p.JID)
		if !p.PhoneNumber.IsEmpty() {
			member = p.PhoneNumber.ToNonAD()
		}
		if member.User == b.selfUser {
			isSelf = true
			continue
		}
		names = append(names, b.memberName(member, ""))
	}
	sort.SliceStable(names, func(i, j int) bool {
		a, c := strings.HasPrefix(names[i], "~"), strings.HasPrefix(names[j], "~")
		if a != c {
			return !a
		}
		return strings.ToLower(strings.TrimPrefix(names[i], "~")) < strings.ToLower(strings.TrimPrefix(names[j], "~"))
	})
	if isSelf {
		names = append(names, "Você")
	}
	b.emit(outEvent{"type": "members", "jid": b.canonical(jid).String(), "names": names})
}

func (b *bridge) refreshNames() {
	b.names.Range(func(key, _ any) bool {
		if jid, err := types.ParseJID(key.(string)); err == nil && jid.Server != types.GroupServer {
			go b.emitName(jid, "")
		}
		return true
	})
}

func (b *bridge) resolveChat(raw string) {
	jid, err := types.ParseJID(raw)
	if err != nil || ignored(jid) {
		return
	}
	canonical := b.canonical(jid)
	if canonical != jid {
		b.emit(outEvent{"type": "merge", "chat": raw, "jid": canonical.String()})
	}
	b.names.Store(canonical.String(), true)
	b.emitName(canonical, "")
	b.emitSettings(canonical)
}

func messageText(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	switch {
	case m.GetConversation() != "":
		return m.GetConversation()
	case m.GetExtendedTextMessage().GetText() != "":
		return m.GetExtendedTextMessage().GetText()
	case m.GetImageMessage() != nil:
		return withCaption("📷 Foto", m.GetImageMessage().GetCaption())
	case m.GetVideoMessage() != nil:
		return withCaption("🎥 Vídeo", m.GetVideoMessage().GetCaption())
	case m.GetAudioMessage() != nil:
		return "🎤 Áudio"
	case m.GetDocumentMessage() != nil:
		return "📄 " + m.GetDocumentMessage().GetFileName()
	case m.GetStickerMessage() != nil:
		return "Figurinha"
	case m.GetLocationMessage() != nil:
		return "📍 Localização"
	case m.GetContactMessage() != nil:
		return "👤 " + m.GetContactMessage().GetDisplayName()
	case m.GetEphemeralMessage() != nil:
		return messageText(m.GetEphemeralMessage().GetMessage())
	case m.GetViewOnceMessage() != nil:
		return messageText(m.GetViewOnceMessage().GetMessage())
	case m.GetEditedMessage() != nil:
		return messageText(m.GetEditedMessage().GetMessage())
	}
	return ""
}

func historyStatus(status waWeb.WebMessageInfo_Status) string {
	switch status {
	case waWeb.WebMessageInfo_READ, waWeb.WebMessageInfo_PLAYED:
		return "read"
	case waWeb.WebMessageInfo_DELIVERY_ACK:
		return "delivered"
	case waWeb.WebMessageInfo_SERVER_ACK:
		return "sent"
	}
	return ""
}

func withCaption(label, caption string) string {
	if caption == "" {
		return label
	}
	return label + " · " + caption
}

func (b *bridge) emitMessage(evt *events.Message, history bool, status ...string) {
	chat := b.canonical(evt.Info.Chat)
	if ignored(chat) {
		return
	}
	if r := evt.Message.GetReactionMessage(); r != nil {
		b.emit(outEvent{"type": "reaction", "chat": chat.String(), "id": r.GetKey().GetID(), "sender": b.canonical(evt.Info.Sender).String(), "fromMe": evt.Info.IsFromMe, "text": r.GetText()})
		return
	}
	if p := evt.Message.GetProtocolMessage(); p != nil && p.GetType() == waE2E.ProtocolMessage_REVOKE {
		b.emit(outEvent{"type": "revoked", "chat": chat.String(), "id": p.GetKey().GetID(), "fromMe": evt.Info.IsFromMe})
		return
	}
	text := messageText(evt.Message)
	if evt.IsViewOnce {
		text = viewOnceText(evt.Message)
	}
	if text == "" {
		return
	}
	media := &mediaInfo{kind: "view_once"}
	if !evt.IsViewOnce {
		media = mediaOf(evt.Message)
	}
	b.emitInfo(evt.Info, text, history, media, evt.Message, status...)
}

func viewOnceText(m *waE2E.Message) string {
	switch {
	case m.GetVideoMessage() != nil:
		return "Vídeo de visualização única"
	case m.GetAudioMessage() != nil:
		return "Áudio de visualização única"
	case m.GetImageMessage() != nil:
		return "Foto de visualização única"
	}
	return "Mensagem de visualização única"
}

func contextOf(m *waE2E.Message) *waE2E.ContextInfo {
	if m == nil {
		return nil
	}
	switch {
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetContextInfo()
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetContextInfo()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetContextInfo()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage().GetContextInfo()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetContextInfo()
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage().GetContextInfo()
	case m.GetLocationMessage() != nil:
		return m.GetLocationMessage().GetContextInfo()
	case m.GetContactMessage() != nil:
		return m.GetContactMessage().GetContextInfo()
	case m.GetDocumentWithCaptionMessage() != nil:
		return contextOf(m.GetDocumentWithCaptionMessage().GetMessage())
	case m.GetEphemeralMessage() != nil:
		return contextOf(m.GetEphemeralMessage().GetMessage())
	case m.GetViewOnceMessage() != nil:
		return contextOf(m.GetViewOnceMessage().GetMessage())
	}
	return nil
}

func quotedThumb(m *waE2E.Message) []byte {
	switch {
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetJPEGThumbnail()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetJPEGThumbnail()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetJPEGThumbnail()
	case m.GetEphemeralMessage() != nil:
		return quotedThumb(m.GetEphemeralMessage().GetMessage())
	case m.GetViewOnceMessage() != nil:
		return quotedThumb(m.GetViewOnceMessage().GetMessage())
	}
	return nil
}

func (b *bridge) addQuote(out outEvent, chat types.JID, msg *waE2E.Message) {
	ctx := contextOf(msg)
	if ctx.GetStanzaID() == "" || ctx.GetQuotedMessage() == nil {
		return
	}
	quoted := ctx.GetQuotedMessage()
	text := messageText(quoted)
	if text == "" {
		text = "Mensagem"
	}
	out["quotedId"] = ctx.GetStanzaID()
	out["quotedText"] = text
	if thumb := quotedThumb(quoted); len(thumb) > 0 {
		out["quotedThumb"] = thumb
	}
	if kind := mediaOf(quoted); kind != nil {
		out["quotedMedia"] = kind.kind
	} else if quoted.GetVideoMessage() != nil {
		out["quotedMedia"] = "video"
	}
	participant, err := types.ParseJID(ctx.GetParticipant())
	if err != nil || participant.User == "" {
		participant = chat
	}
	participant = b.canonical(participant)
	fromMe := participant.User == b.selfUser
	if !fromMe && b.client.Store.LID.User != "" {
		fromMe = participant.User == b.client.Store.LID.User
	}
	out["quotedFromMe"] = fromMe
	out["quotedSender"] = participant.ToNonAD().String()
	if !fromMe {
		out["quotedSenderName"] = b.memberName(participant, "")
	}
}

func (b *bridge) emitInfo(info types.MessageInfo, text string, history bool, media *mediaInfo, msg *waE2E.Message, status ...string) {
	ext := msg.GetExtendedTextMessage()
	chat := b.canonical(info.Chat)
	sender := b.canonical(info.Sender)
	senderName := info.PushName
	if senderName == "" && !info.IsFromMe {
		senderName = b.contactName(sender)
	}
	hint := ""
	if !info.IsGroup && !info.IsFromMe {
		hint = info.PushName
	}
	b.resolveName(chat, hint)
	out := outEvent{
		"type":       "message",
		"chat":       chat.String(),
		"id":         info.ID,
		"sender":     sender.String(),
		"senderName": senderName,
		"fromMe":     info.IsFromMe,
		"isGroup":    info.IsGroup,
		"text":       text,
		"timestamp":  info.Timestamp.Unix(),
		"history":    history,
	}
	if len(status) > 0 && status[0] != "" {
		out["status"] = status[0]
	}
	if ext != nil && (ext.GetMatchedText() != "" || ext.GetTitle() != "") {
		out["previewURL"] = ext.GetMatchedText()
		out["previewTitle"] = ext.GetTitle()
		out["previewDescription"] = ext.GetDescription()
		if thumb := ext.GetJPEGThumbnail(); len(thumb) > 0 {
			out["previewThumb"] = thumb
		}
	}
	b.addQuote(out, chat, msg)
	if media != nil && media.kind == "view_once" {
		out["media"] = media.kind
	} else if media != nil {
		out["media"] = media.kind
		out["caption"] = media.caption
		out["path"] = b.prepareMedia(chat, info.ID, media, history)
		if media.kind == "document" {
			out["fileName"] = media.fileName
			out["fileSize"] = media.size
		}
		if media.kind == "audio" {
			out["seconds"] = media.seconds
			out["waveform"] = media.waveform
			out["ptt"] = media.ptt
		}
	}
	b.emit(out)
}

func (b *bridge) handle(raw any) {
	switch evt := raw.(type) {
	case *events.Message:
		b.emitMessage(evt, false)
	case *events.UndecryptableMessage:
		if evt.UnavailableType == events.UnavailableTypeViewOnce && !ignored(b.canonical(evt.Info.Chat)) {
			b.emitInfo(evt.Info, viewOnceText(nil), false, &mediaInfo{kind: "view_once"}, nil)
		}
	case *events.HistorySync:
		for _, conv := range evt.Data.GetConversations() {
			chatJID, err := types.ParseJID(conv.GetID())
			if err != nil {
				continue
			}
			chat := b.canonical(chatJID)
			if ignored(chat) {
				continue
			}
			if conv.GetName() != "" {
				b.names.Store(chat.String(), true)
				b.emit(outEvent{"type": "chat", "jid": chat.String(), "name": conv.GetName(), "isGroup": chat.Server == types.GroupServer})
			} else {
				b.resolveName(chat, "")
			}
			msgs := conv.GetMessages()
			for i := len(msgs) - 1; i >= 0; i-- {
				parsed, err := b.client.ParseWebMessage(chatJID, msgs[i].GetMessage())
				if err == nil {
					b.emitMessage(parsed, true, historyStatus(msgs[i].GetMessage().GetStatus()))
				}
			}
			if conv.GetUnreadCount() > 0 {
				b.emit(outEvent{"type": "unread", "chat": chat.String(), "count": conv.GetUnreadCount()})
			}
		}
	case *events.Receipt:
		status := ""
		switch evt.Type {
		case types.ReceiptTypeDelivered:
			status = "delivered"
		case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
			status = "read"
		}
		if status != "" {
			b.emit(outEvent{"type": "receipt", "chat": b.canonical(evt.Chat).String(), "ids": evt.MessageIDs, "status": status})
		}
	case *events.Connected:
		b.emitConnected()
		go b.syncAllSettings()
		go b.refreshBlocklist()
		go b.resyncLocks()
	case *events.Picture:
		go b.fetchAvatar(b.canonical(evt.JID), "")
	case *events.PushName:
		jid := b.canonical(evt.JID)
		if _, known := b.names.Load(jid.String()); known {
			go b.emitName(jid, evt.NewPushName)
		}
	case *events.Contact:
		jid := b.canonical(evt.JID)
		if _, known := b.names.Load(jid.String()); known {
			go b.emitName(jid, "")
		}
	case *events.AppStateSyncComplete:
		b.refreshNames()
		go b.syncAllSettings()
	case *events.Archive:
		b.emitSetting(evt.JID, "archived", evt.Action.GetArchived())
	case *events.Pin:
		b.emitSetting(evt.JID, "pinned", evt.Action.GetPinned())
	case *events.AppState:
		if len(evt.Index) > 1 && evt.Index[0] == appstate.IndexLock && evt.GetLockChatAction() != nil {
			if jid, err := types.ParseJID(evt.Index[1]); err == nil {
				b.emitSetting(jid, "locked", evt.GetLockChatAction().GetLocked())
			}
		}
	case *events.MarkChatAsRead:
		b.emitSetting(evt.JID, "unread", !evt.Action.GetRead())
	case *events.DeleteChat:
		if jid := b.canonical(evt.JID); !ignored(jid) {
			b.emit(outEvent{"type": "deleted", "jid": jid.String()})
		}
	case *events.Blocklist:
		go b.refreshBlocklist()
	case *events.Mute:
		b.emitSetting(evt.JID, "muted", evt.Action.GetMuted())
	case *events.LoggedOut:
		b.emit(outEvent{"type": "logged_out"})
	case *events.StreamReplaced:
		b.emit(outEvent{"type": "error", "message": "Sessão aberta em outro lugar"})
	case *events.Disconnected:
		b.emit(outEvent{"type": "disconnected"})
	}
}

func (b *bridge) emitConnected() {
	id := b.client.Store.ID
	if id == nil {
		return
	}
	b.selfUser = id.User
	b.emit(outEvent{"type": "connected", "jid": id.ToNonAD().String(), "name": b.client.Store.PushName})
}

func (b *bridge) send(cmd command) {
	jid, err := types.ParseJID(cmd.Chat)
	if err != nil {
		b.emit(outEvent{"type": "send_failed", "tempId": cmd.TempID, "message": err.Error()})
		return
	}
	msg := &waE2E.Message{Conversation: proto.String(cmd.Text)}
	if ctx := b.replyContext(jid, cmd); ctx != nil {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(cmd.Text), ContextInfo: ctx}}
	}
	resp, err := b.client.SendMessage(b.ctx, jid, msg)
	if err != nil {
		b.emit(outEvent{"type": "send_failed", "tempId": cmd.TempID, "message": err.Error()})
		return
	}
	b.emit(outEvent{"type": "sent", "tempId": cmd.TempID, "id": resp.ID, "chat": cmd.Chat, "timestamp": resp.Timestamp.Unix()})
}

func (b *bridge) replyContext(chat types.JID, cmd command) *waE2E.ContextInfo {
	if cmd.QuotedID == "" {
		return nil
	}
	participant := chat
	if cmd.QuotedFromMe {
		if id := b.client.Store.ID; id != nil {
			participant = id.ToNonAD()
		}
	} else if parsed, err := types.ParseJID(cmd.QuotedSender); err == nil && parsed.User != "" {
		participant = parsed
	}
	return &waE2E.ContextInfo{
		StanzaID:      proto.String(cmd.QuotedID),
		Participant:   proto.String(participant.ToNonAD().String()),
		QuotedMessage: &waE2E.Message{Conversation: proto.String(cmd.QuotedText)},
	}
}

func stickerData(data []byte) ([]byte, bool, uint32, uint32, error) {
	if len(data) > 12 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		animated := bytes.Contains(data[:min(len(data), 4096)], []byte("ANIM"))
		width, height := uint32(512), uint32(512)
		if config, err := xwebp.DecodeConfig(bytes.NewReader(data)); err == nil {
			width, height = uint32(config.Width), uint32(config.Height)
		}
		return data, animated, width, height, nil
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, false, 0, 0, err
	}
	var buf bytes.Buffer
	if err := nativewebp.Encode(&buf, img, nil); err != nil {
		return nil, false, 0, 0, err
	}
	bounds := img.Bounds()
	return buf.Bytes(), false, uint32(bounds.Dx()), uint32(bounds.Dy()), nil
}

func optional(value string) *string {
	if value == "" {
		return nil
	}
	return proto.String(value)
}

func (b *bridge) sendMedia(cmd command) {
	failed := func(err error) {
		b.emit(outEvent{"type": "send_failed", "tempId": cmd.TempID, "message": err.Error()})
	}
	jid, err := types.ParseJID(cmd.Chat)
	if err != nil {
		failed(err)
		return
	}
	data, err := os.ReadFile(cmd.Path)
	if err != nil {
		failed(err)
		return
	}
	animated := false
	if cmd.Kind == "sticker" {
		data, animated, cmd.Width, cmd.Height, err = stickerData(data)
		if err != nil {
			failed(err)
			return
		}
	}
	mediaType := map[string]whatsmeow.MediaType{
		"image":   whatsmeow.MediaImage,
		"sticker": whatsmeow.MediaImage,
		"video":   whatsmeow.MediaVideo,
		"audio":   whatsmeow.MediaAudio,
		"voice":   whatsmeow.MediaAudio,
	}[cmd.Kind]
	if mediaType == "" {
		mediaType = whatsmeow.MediaDocument
	}
	ctx, cancel := context.WithTimeout(b.ctx, 10*time.Minute)
	defer cancel()
	up, err := b.client.Upload(ctx, data, mediaType)
	if err != nil {
		failed(err)
		return
	}
	length := proto.Uint64(up.FileLength)
	var msg *waE2E.Message
	switch cmd.Kind {
	case "image":
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String(cmd.Mime), Caption: optional(cmd.Text), JPEGThumbnail: cmd.Thumb,
			Width: proto.Uint32(cmd.Width), Height: proto.Uint32(cmd.Height),
		}}
	case "video":
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String(cmd.Mime), Caption: optional(cmd.Text), JPEGThumbnail: cmd.Thumb,
			Width: proto.Uint32(cmd.Width), Height: proto.Uint32(cmd.Height), Seconds: proto.Uint32(cmd.Seconds),
		}}
	case "sticker":
		msg = &waE2E.Message{StickerMessage: &waE2E.StickerMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String("image/webp"), Width: proto.Uint32(cmd.Width), Height: proto.Uint32(cmd.Height),
			IsAnimated: proto.Bool(animated),
		}}
	case "voice":
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String("audio/ogg; codecs=opus"), Seconds: proto.Uint32(cmd.Seconds), PTT: proto.Bool(true),
			Waveform: cmd.Waveform,
		}}
	case "audio":
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String(cmd.Mime), Seconds: proto.Uint32(cmd.Seconds), PTT: proto.Bool(false),
		}}
	default:
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: length,
			Mimetype: proto.String(cmd.Mime), FileName: proto.String(cmd.FileName), Title: proto.String(cmd.FileName),
			Caption: optional(cmd.Text), JPEGThumbnail: cmd.Thumb,
		}}
	}
	if ctx := b.replyContext(jid, cmd); ctx != nil {
		switch {
		case msg.ImageMessage != nil:
			msg.ImageMessage.ContextInfo = ctx
		case msg.VideoMessage != nil:
			msg.VideoMessage.ContextInfo = ctx
		case msg.StickerMessage != nil:
			msg.StickerMessage.ContextInfo = ctx
		case msg.AudioMessage != nil:
			msg.AudioMessage.ContextInfo = ctx
		case msg.DocumentMessage != nil:
			msg.DocumentMessage.ContextInfo = ctx
		}
	}
	resp, err := b.client.SendMessage(b.ctx, jid, msg)
	if err != nil {
		failed(err)
		return
	}
	out := outEvent{"type": "sent", "tempId": cmd.TempID, "id": resp.ID, "chat": cmd.Chat, "timestamp": resp.Timestamp.Unix()}
	if ext := map[string]string{"image": ".jpg", "sticker": ".webp", "voice": ".ogg"}[cmd.Kind]; ext != "" {
		saved := filepath.Join(b.mediaDir, safeName(cmd.Chat, resp.ID)+ext)
		if writeFile(saved, data) == nil {
			out["path"] = saved
		}
	}
	b.emit(out)
}

func (b *bridge) react(cmd command) {
	chat, err := types.ParseJID(cmd.Chat)
	if err != nil {
		return
	}
	sender := types.EmptyJID
	if !cmd.FromMe && cmd.Sender != "" {
		if parsed, err := types.ParseJID(cmd.Sender); err == nil {
			sender = parsed
		}
	}
	if _, err := b.client.SendMessage(b.ctx, chat, b.client.BuildReaction(chat, sender, cmd.ID, cmd.Text)); err != nil {
		b.fail("react", err)
	}
}

func (b *bridge) revoke(cmd command) {
	chat, err := types.ParseJID(cmd.Chat)
	if err != nil {
		return
	}
	for _, id := range cmd.IDs {
		if _, err := b.client.RevokeMessage(b.ctx, chat, id); err != nil {
			b.fail("revoke", err)
		}
	}
}

func (b *bridge) markRead(cmd command) {
	chat, err := types.ParseJID(cmd.Chat)
	if err != nil || len(cmd.IDs) == 0 {
		return
	}
	sender := chat
	if cmd.Sender != "" {
		if s, err := types.ParseJID(cmd.Sender); err == nil {
			sender = s
		}
	}
	if err := b.client.MarkRead(b.ctx, cmd.IDs, time.Now(), chat, sender); err != nil {
		b.fail("mark_read", err)
	}
}

func (b *bridge) fetchAvatar(jid types.JID, existingID string) {
	if ignored(jid) {
		return
	}
	b.avatarSlot <- struct{}{}
	defer func() { <-b.avatarSlot }()
	info, err := b.client.GetProfilePictureInfo(b.ctx, jid, &whatsmeow.GetProfilePictureParams{Preview: true, ExistingID: existingID})
	if errors.Is(err, whatsmeow.ErrProfilePictureNotSet) || errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized) {
		os.Remove(b.avatarPath(jid))
		b.emit(outEvent{"type": "avatar", "jid": jid.String(), "pictureId": "", "path": ""})
		return
	}
	if err != nil || info == nil || info.URL == "" {
		return
	}
	path := b.avatarPath(jid)
	if err := download(b.ctx, info.URL, path); err != nil {
		return
	}
	b.emit(outEvent{"type": "avatar", "jid": jid.String(), "pictureId": info.ID, "path": path})
}

func (b *bridge) avatarPath(jid types.JID) string {
	return filepath.Join(b.avatarDir, jid.String()+".jpg")
}

func download(ctx context.Context, url, path string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".avatar-*")
	if err != nil {
		return err
	}
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	tmp.Close()
	return os.Rename(tmp.Name(), path)
}

func (b *bridge) emitContacts() {
	all, err := b.client.Store.Contacts.GetAllContacts(b.ctx)
	if err != nil {
		b.fail("contacts", err)
		return
	}
	seen := map[string]bool{}
	list := []map[string]string{}
	for jid, info := range all {
		name := info.FullName
		if name == "" {
			name = info.FirstName
		}
		if name == "" {
			continue
		}
		canonical := b.canonical(jid)
		if ignored(canonical) || canonical.User == b.selfUser {
			continue
		}
		key := canonical.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		list = append(list, map[string]string{"jid": key, "name": name})
	}
	b.emit(outEvent{"type": "contacts", "contacts": list})
}

func (b *bridge) readCommands() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for scanner.Scan() {
		var cmd command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			continue
		}
		switch cmd.Cmd {
		case "send":
			go b.send(cmd)
		case "react":
			go b.react(cmd)
		case "revoke":
			go b.revoke(cmd)
		case "members":
			go b.emitMembers(cmd.Chat)
		case "send_media":
			go b.sendMedia(cmd)
		case "mark_read":
			go b.markRead(cmd)
		case "delete":
			go b.deleteChat(cmd)
		case "contacts":
			go b.emitContacts()
		case "block":
			go b.block(cmd)
		case "archive", "pin", "mute", "read":
			go b.changeSetting(cmd)
		case "resolve":
			go b.resolveChat(cmd.Chat)
		case "avatar":
			if jid, err := types.ParseJID(cmd.Chat); err == nil {
				go b.fetchAvatar(jid, cmd.PictureID)
			}
		case "logout":
			if err := b.client.Logout(b.ctx); err != nil {
				b.fail("logout", err)
			}
			b.emit(outEvent{"type": "logged_out"})
			os.Exit(0)
		}
	}
	b.client.Disconnect()
	os.Exit(0)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: watt-bridge <db-path>")
		os.Exit(2)
	}
	ctx := context.Background()
	b := &bridge{ctx: ctx, avatarSlot: make(chan struct{}, 4)}
	b.avatarDir = filepath.Join(filepath.Dir(os.Args[1]), "avatars")
	os.MkdirAll(b.avatarDir, 0o755)
	b.mediaDir = filepath.Join(filepath.Dir(os.Args[1]), "media")
	b.mediaSlot = make(chan struct{}, 3)
	os.MkdirAll(b.mediaDir, 0o755)
	logger := waLog.Noop
	store.SetOSInfo("Watt (macOS)", [3]uint32{1, 0, 0})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()

	dsn := "file:" + os.Args[1] + "?_foreign_keys=on"
	container, err := sqlstore.New(ctx, "sqlite3", dsn, logger)
	if err != nil {
		b.fail("database", err)
		os.Exit(1)
	}
	b.db, _ = sql.Open("sqlite3", dsn+"&mode=ro")
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		b.fail("device", err)
		os.Exit(1)
	}

	b.client = whatsmeow.NewClient(device, logger)
	b.client.EmitAppStateEventsOnFullSync = true
	b.client.AddEventHandler(b.handle)
	go b.readCommands()

	if b.client.Store.ID == nil {
		qr, _ := b.client.GetQRChannel(ctx)
		if err := b.client.Connect(); err != nil {
			b.fail("connect", err)
			os.Exit(1)
		}
		for item := range qr {
			switch item.Event {
			case "code":
				b.emit(outEvent{"type": "qr", "code": item.Code})
			case "success":
				b.emit(outEvent{"type": "paired"})
			case "timeout":
				b.emit(outEvent{"type": "qr_timeout"})
			default:
				if item.Error != nil {
					b.fail("pair", item.Error)
				}
			}
		}
	} else {
		if err := b.client.Connect(); err != nil {
			b.fail("connect", err)
			os.Exit(1)
		}
	}

	select {}
}
