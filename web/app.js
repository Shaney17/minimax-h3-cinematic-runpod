const $ = (id) => document.getElementById(id);
const NODE_IDS = ["28", "29", "30"];
const MAX_BODY_BYTES = 9_500_000;
const TERMINAL_STATES = new Set(["COMPLETED", "FAILED", "CANCELLED", "TIMED_OUT"]);

const state = {
  workflow: null,
  workflowName: "",
  defaultPrompt: "",
  promptTouched: false,
  jobId: null,
  timer: null,
  previewUrls: [null, null, null],
  videoUrl: null,
};

function sizeLabel(bytes) {
  return bytes < 1024 * 1024 ? `${Math.ceil(bytes / 1024)} KB` : `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function showError(message) {
  const box = $("job-error");
  box.textContent = message;
  box.hidden = false;
  $("status-description").textContent = "Yêu cầu chưa hoàn tất. Xem thông báo bên dưới.";
}

function clearError() {
  $("job-error").hidden = true;
  $("job-error").textContent = "";
}

function workflowAlert(message) {
  const box = $("workflow-alert");
  box.textContent = message;
  box.hidden = !message;
}

function setProgress(step, description) {
  const order = ["submitted", "queued", "running", "completed"];
  const index = order.indexOf(step);
  document.querySelectorAll(".status-item").forEach((item, position) => {
    item.classList.toggle("active", position === index);
    item.classList.toggle("done", position < index);
  });
  $("progress-fill").style.width = `${Math.max(0, index + 1) * 25}%`;
  $("status-description").textContent = description;
}

function resetResult() {
  $("result").hidden = true;
  $("result-video").hidden = true;
  $("result-video").removeAttribute("src");
  $("result-video").load();
  if (state.videoUrl) URL.revokeObjectURL(state.videoUrl);
  state.videoUrl = null;
}

function validateWorkflow(graph) {
  if (!graph || Array.isArray(graph) || typeof graph !== "object") {
    throw new Error("Workflow API cài sẵn không hợp lệ.");
  }
  if (Array.isArray(graph.nodes) && Array.isArray(graph.links)) {
    throw new Error("Workflow cài sẵn vẫn là định dạng giao diện.");
  }
  for (const id of NODE_IDS) {
    if (graph[id]?.class_type !== "LoadImage" || !graph[id].inputs) {
      throw new Error(`Không tìm thấy nút LoadImage ${id} trong workflow cài sẵn.`);
    }
  }
  if (graph["190"]?.class_type !== "PrimitiveStringMultiline" || !graph["190"].inputs) {
    throw new Error("Không tìm thấy nút prompt 190 trong workflow API Cinematic.");
  }
  const referenceNode = Object.values(graph).find((node) => node?.class_type === "MiniMaxH3ReferenceToVideo");
  const connectedMedia = Object.entries(referenceNode?.inputs || {}).some(([name, value]) =>
    /^(ref_videos\.|ref_audios\.|ref_video_audios\.)/.test(name) && Array.isArray(value)
  );
  if (connectedMedia) {
    throw new Error("Workflow cài sẵn còn nhánh tải video/âm thanh tham chiếu không được hỗ trợ.");
  }
}

async function loadBundledWorkflow() {
  state.workflow = null;
  state.workflowName = "";
  workflowAlert("");
  $("workflow-title").textContent = "Đang tải workflow…";
  try {
    const response = await fetch("/api/workflow");
    if (!response.ok) throw new Error("Không tải được workflow API cài sẵn.");
    const graph = await response.json();
    validateWorkflow(graph);
    state.workflow = graph;
    state.workflowName = "Cinematic · 3 ảnh";
    $("workflow-title").textContent = state.workflowName;
    $("workflow-detail").textContent = `${Object.keys(graph).length} nút · ảnh sẽ gắn vào nút 28, 29, 30`;
    if (!state.promptTouched && typeof graph["190"].inputs.value === "string") {
      $("prompt-text").value = graph["190"].inputs.value;
      updatePromptCount();
    }
  } catch (error) {
    $("workflow-title").textContent = "Chưa tải được workflow";
    workflowAlert(error.message || "Không đọc được workflow.");
  }
}

function previewImage(index, file) {
  const img = $(`preview-${index}`);
  const label = $(`image-label-${index}`);
  if (state.previewUrls[index - 1]) URL.revokeObjectURL(state.previewUrls[index - 1]);
  state.previewUrls[index - 1] = null;
  img.hidden = true;
  label.hidden = false;
  $(`image-meta-${index}`).textContent = "PNG, JPG hoặc WebP";
  if (!file) return;
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) {
    showError(`Ảnh ${index} phải là PNG, JPG hoặc WebP.`);
    $(`image-${index}`).value = "";
    return;
  }
  state.previewUrls[index - 1] = URL.createObjectURL(file);
  img.src = state.previewUrls[index - 1];
  img.hidden = false;
  label.hidden = true;
  $(`image-meta-${index}`).textContent = `${file.name} · ${sizeLabel(file.size)}`;
  clearError();
}

function toDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error(`Không đọc được tệp ${file.name}.`));
    reader.readAsDataURL(file);
  });
}

async function apiRequest(url, options = {}) {
  const key = $("api-key").value.trim();
  const response = await fetch(url, {
    ...options,
    headers: {
      "X-Runpod-Key": key,
      ...(options.body ? { "Content-Type": "application/json" } : {}),
    },
  });
  const raw = await response.text();
  let data;
  try { data = JSON.parse(raw); } catch { throw new Error(`Runpod trả dữ liệu không phải JSON (HTTP ${response.status}).`); }
  if (!response.ok) {
    const detail = data.error || data.message || raw.slice(0, 300);
    throw new Error(`HTTP ${response.status}: ${typeof detail === "string" ? detail : JSON.stringify(detail)}`);
  }
  return data;
}

async function buildRequest() {
  const graph = structuredClone(state.workflow);
  const prompt = $("prompt-text").value.trim();
  if (!prompt) throw new Error("Hãy nhập prompt video.");
  graph["190"].inputs.value = prompt;
  const images = [];
  for (let index = 1; index <= 3; index++) {
    const file = $(`image-${index}`).files[0];
    if (!file) throw new Error(`Hãy chọn ảnh tham chiếu ${index}.`);
    const safeName = file.name.replace(/[^A-Za-z0-9._-]/g, "_");
    const name = `h3_ref_${index}_${Date.now()}_${safeName}`;
    graph[NODE_IDS[index - 1]].inputs.image = name;
    images.push({ name, image: await toDataUrl(file) });
  }
  const request = {
    input: { workflow: graph, images },
    policy: { executionTimeout: 1_200_000, ttl: 3_600_000 },
  };
  const body = JSON.stringify(request);
  if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) {
    throw new Error("Ba ảnh và workflow vượt giới hạn 9,5 MB. Hãy giảm kích thước ảnh rồi thử lại.");
  }
  return body;
}

function renderVideo(output) {
  if (output?.error) throw new Error(typeof output.error === "string" ? output.error : JSON.stringify(output.error));
  const videos = Array.isArray(output?.videos) ? output.videos : [];
  if (!videos.length) {
    throw new Error("Job hoàn tất nhưng worker không trả video MP4. Hãy xem output và log trên Runpod.");
  }
  const video = videos[videos.length - 1];
  const download = $("download-video");
  const player = $("result-video");
  if (video.type === "s3_url" && typeof video.data === "string" && /^https:\/\//.test(video.data)) {
    download.href = video.data;
    download.textContent = "Mở / tải video ↗";
    download.removeAttribute("download");
    player.src = video.data;
    player.hidden = false;
    $("result-note").textContent = video.filename || "Video được lưu trên S3.";
  } else if (video.type === "base64" && typeof video.data === "string") {
    const binary = atob(video.data.replace(/^data:[^,]+,/, ""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    state.videoUrl = URL.createObjectURL(new Blob([bytes], { type: "video/mp4" }));
    download.href = state.videoUrl;
    download.download = video.filename || "minimax-h3-cinematic.mp4";
    download.textContent = "Tải video MP4 ↓";
    player.src = state.videoUrl;
    player.hidden = false;
    $("result-note").textContent = `${video.filename || "MP4"} · ${sizeLabel(bytes.length)}`;
  } else {
    throw new Error("Worker trả định dạng video chưa được giao diện hỗ trợ.");
  }
  $("result").hidden = false;
}

async function checkStatus() {
  try {
    const data = await apiRequest(`/api/status/${encodeURIComponent(state.jobId)}`);
    const status = String(data.status || "").toUpperCase();
    if (status === "IN_QUEUE") setProgress("queued", "Job đang trong hàng đợi. Worker sẽ khởi động khi đến lượt.");
    else if (status === "IN_PROGRESS") setProgress("running", "Worker đang xử lý workflow. Render video có thể mất nhiều phút.");
    else if (status === "COMPLETED") {
      setProgress("completed", "Worker đã hoàn tất. Video sẵn sàng bên dưới.");
      renderVideo(data.output);
    } else if (TERMINAL_STATES.has(status)) {
      throw new Error(`${status}: ${typeof data.error === "string" ? data.error : JSON.stringify(data.error || data.output || "Không có chi tiết lỗi.")}`);
    } else {
      $("status-description").textContent = `Trạng thái Runpod: ${status || "chưa rõ"}`;
    }
    if (!TERMINAL_STATES.has(status)) state.timer = setTimeout(checkStatus, 5000);
    else $("submit-button").disabled = false;
  } catch (error) {
    showError(error.message || "Không kiểm tra được trạng thái job.");
    $("submit-button").disabled = false;
  }
}

async function submit(event) {
  event.preventDefault();
  clearError();
  resetResult();
  if (state.timer) clearTimeout(state.timer);
  if (!$("api-key").value.trim()) return showError("Hãy nhập Runpod API key.");
  if (!state.workflow) return showError("Workflow API chưa tải được. Hãy tải lại trang.");
  $("submit-button").disabled = true;
  $("job-info").hidden = true;
  state.jobId = null;
  setProgress("submitted", "Đang chuẩn bị ảnh và gửi request đến Runpod…");
  try {
    const body = await buildRequest();
    const data = await apiRequest("/api/run", { method: "POST", body });
    if (!data.id) throw new Error(`Runpod chưa trả Job ID: ${JSON.stringify(data).slice(0, 250)}`);
    state.jobId = data.id;
    $("job-id").textContent = data.id;
    $("job-info").hidden = false;
    setProgress("queued", "Request đã được nhận. Đang chờ worker xử lý…");
    state.timer = setTimeout(checkStatus, 2500);
  } catch (error) {
    showError(error.message || "Không gửi được request.");
    $("submit-button").disabled = false;
  }
}

$("request-form").addEventListener("submit", submit);
loadBundledWorkflow();
for (let index = 1; index <= 3; index++) {
  $(`image-${index}`).addEventListener("change", (event) => previewImage(index, event.target.files[0]));
}
$("toggle-key").addEventListener("click", () => {
  const input = $("api-key");
  input.type = input.type === "password" ? "text" : "password";
  $("toggle-key").textContent = input.type === "password" ? "Hiện" : "Ẩn";
  $("toggle-key").setAttribute("aria-label", input.type === "password" ? "Hiện API key" : "Ẩn API key");
});
$("copy-id").addEventListener("click", async () => {
  if (!state.jobId) return;
  await navigator.clipboard.writeText(state.jobId);
  $("copy-id").textContent = "Đã sao chép";
  setTimeout(() => { $("copy-id").textContent = "Sao chép"; }, 2000);
});

function updatePromptCount() {
  $("prompt-count").textContent = `${$("prompt-text").value.length.toLocaleString("vi-VN")} ký tự`;
}

$("prompt-text").addEventListener("input", () => {
  state.promptTouched = true;
  updatePromptCount();
});
$("reset-prompt").addEventListener("click", () => {
  if (!state.defaultPrompt) return;
  $("prompt-text").value = state.defaultPrompt;
  state.promptTouched = false;
  updatePromptCount();
});

fetch("/api/default-prompt")
  .then((response) => {
    if (!response.ok) throw new Error("Không tải được prompt gốc.");
    return response.json();
  })
  .then((data) => {
    state.defaultPrompt = data.prompt || "";
    if (!state.promptTouched) $("prompt-text").value = state.defaultPrompt;
    $("prompt-text").placeholder = "Nhập prompt video của bạn…";
    updatePromptCount();
  })
  .catch(() => { $("prompt-text").placeholder = "Nhập prompt video của bạn…"; });
