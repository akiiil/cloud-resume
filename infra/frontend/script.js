function toggleMenu() {
  const menu = document.querySelector(".menu-links");
  const icon = document.querySelector(".hamburger-icon");
  menu.classList.toggle("open");
  icon.classList.toggle("open");
}

document.getElementById("copy-email").addEventListener("click", function () {
  const email = "akil.mohamed2@gmail.com";
  navigator.clipboard.writeText(email).then(() => {
    showCopyToast("Email copied to clipboard");
  }).catch((err) => {
    console.error("Failed to copy: ", err);
  });
});

function showCopyToast(message) {
  // Check if toast already exists
  let toast = document.getElementById("copy-toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "copy-toast";
    toast.style.position = "fixed";
    toast.style.bottom = "40px";
    toast.style.left = "50%";
    toast.style.transform = "translateX(-50%)";
    toast.style.background = "#003366";
    toast.style.color = "white";
    toast.style.padding = "10px 20px";
    toast.style.borderRadius = "20px";
    toast.style.fontSize = "14px";
    toast.style.boxShadow = "0px 4px 8px rgba(0,0,0,0.2)";
    toast.style.zIndex = "9999";
    toast.style.opacity = "0";
    toast.style.transition = "opacity 0.3s ease";

    document.body.appendChild(toast);
  }

  toast.textContent = message;
  toast.style.opacity = "1";

  setTimeout(() => {
    toast.style.opacity = "0";
  }, 2000);
}

// Fetch visitor count IMMEDIATELY
  fetch('https://a2epboordh.execute-api.ap-southeast-2.amazonaws.com/')
  .then(response => response.json())
  .then(data => {
    document.getElementById("VisitorCounter").textContent = data.viewercount;
  })
  .catch(err => {
    console.error("Failed to fetch viewer count:", err);
  });