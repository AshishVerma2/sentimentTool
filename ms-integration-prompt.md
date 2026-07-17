I need to integrate with a voice sentiment analysis server over WebSocket using the BWMA protocol.

## What to implement

When a call starts on a BOT agent, open a WebSocket connection to ws://172.28.129.220:2700 and fork the call audio to it in real time. If the server sends a BADSENTIMENT message, redirect the call from BOT agent to a human agent.

## Protocol

**Step 1 - Connect and send BwmaInitializeMessage (JSON text):**
```json
{
    "minimumVersion": 0,
    "maximumVersion": 1,
    "capabilities": ["UTTERANCE_DETECT"],
    "requiredCapabilities": ["UTTERANCE_DETECT"],
    "format": "MONO",
    "executionInfo": {
        "contactId": <contactId>,
        "busNo": <busNo>,
        "requestId": 1,
        "actionId": 0,
        "actionType": "WebSocketRelay",
        "scriptName": "SentimentAnalysis"
    },
    "systemTelemetryData": {
        "consumerProcessHost": "<this server hostname>",
        "consumerProcessName": "EsnMediaServer",
        "consumerProcessVersion": "1.0.0"
    },
    "appConfig": {},
    "appParams": {},
    "authenticationToken": "",
    "streamsConfiguration": null,
    "streamPerspective": "TX_RELAY"
}
```

**Step 2 - Wait for handshake response (JSON text):**
```json
{
    "Message": "BEGIN AUDIO STREAM",
    "MessageType": "COMMAND",
    "ProtocolVersion": 1,
    "Format": "MONO",
    "AgreedCapabilities": ["UTTERANCE_DETECT"],
    "Parameters": {}
}
```

**Step 3 - Stream audio:**
Send binary frames of G.711 mu-law encoded audio, 160 bytes per frame (8kHz, 20ms per frame), continuously while the call is active.

**Step 4 - Listen for BADSENTIMENT (JSON text):**
```json
{
    "MessageType": "BADSENTIMENT",
    "Parameters": {
        "contactId": <contactId>,
        "count": 3
    }
}
```
On receiving this: call `MRC.IssueBlindTransferAction()` to redirect the call to a human agent queue.

**Step 5 - Close WebSocket when call ends.**

## Existing patterns in this codebase
- WebSocket audio is already handled via `OnWebSocketTextMessageReceived` and `OnWebSocketBinaryMessageReceived`
- Blind transfer uses `IGC_BlindTransferCallWithRouteInfo`
- Rhapsody model handles call state transitions
- Look at existing WebSocket relay actions for reference implementation

## Requirements
- One WebSocket connection per active call (not shared)
- Non-blocking - audio streaming must not delay RTP processing
- Handle connection failure gracefully (log + continue call normally)
- Close connection on call end or transfer
