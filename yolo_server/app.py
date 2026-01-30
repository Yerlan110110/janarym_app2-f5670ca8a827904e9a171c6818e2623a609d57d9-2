from fastapi import FastAPI, UploadFile, File
from PIL import Image
import io
from ultralytics import YOLO

app = FastAPI()

model = YOLO("yolov8n.pt")  # модель скачает сама при первом запуске

@app.post("/detect")
async def detect(file: UploadFile = File(...)):
    image_bytes = await file.read()
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")

    results = model(image)[0]
    detections = []
    for box in results.boxes:
        detections.append({
            "label": model.names[int(box.cls)],
            "confidence": float(box.conf),
            "bbox": [float(x) for x in box.xyxy[0]],
        })

    return {"detections": detections}
