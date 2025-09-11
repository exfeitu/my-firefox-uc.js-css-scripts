// @filename     sidebarResizerAndAutohide.uc.js
// @description  Add drag-to-resize and autohide toggle for Firefox sidebar 
// @version      1.4
// @author       exfeitu
// ==/UserScript==

(function () {
    'use strict';

    // 全局防重初始化
    if (window._sidebarResizerAndAutohideInitialized) return;
    window._sidebarResizerAndAutohideInitialized = true;

    // 日志输出优化
    const DEBUG = true;
    function log(...args) {
        if (DEBUG) console.log("[SidebarResizerAndAutohide]", ...args);
    }

    // SVG 图标数据
    const ICONS = {
        locked: 'image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="%23666666"/></svg>',
        autohide: 'image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><circle cx="8" cy="8" r="8" fill="%23666666"/></svg>'
    };

    // 异步等待元素函数 - 非阻塞
    function waitForElement(selector, timeout = 10000) {
        return new Promise((resolve, reject) => {
            // 先检查是否已经存在
            const element = document.querySelector(selector);
            if (element) {
                log("Element found immediately:", selector);
                resolve(element);
                return;
            }

            // 使用 MutationObserver 监听 DOM 变化
            const observer = new MutationObserver((mutations) => {
                const element = document.querySelector(selector);
                if (element) {
                    log("Element found via observer:", selector);
                    observer.disconnect();
                    resolve(element);
                }
            });

            // 开始观察
            observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true
            });

            // 超时处理
            if (timeout > 0) {
                setTimeout(() => {
                    observer.disconnect();
                    reject(new Error(`Timeout waiting for element: ${selector}`));
                }, timeout);
            }
        });
    }

    // 初始化主函数 - 分步异步执行
    async function initSidebarResizerAndAutohide() {
        try {
            log("开始初始化侧边栏功能...");

            // 等待关键元素加载
            await Promise.all([
                waitForElement('#sidebar-box'),
                waitForElement('#nav-bar')
            ]);

            // 异步执行各项初始化
            setTimeout(() => {
                loadSavedWidth();
                createResizer();
                initSidebarAutohide();
            }, 0); // 放入下一个事件循环

        } catch (e) {
            console.error('Sidebar initialization failed:', e);
        }
    }

    // 创建拖动手柄
    function createResizer() {
        try {
            const sidebarBox = document.getElementById('sidebar-box');
            if (!sidebarBox) {
                console.warn("[SidebarResizer] sidebar-box not found");
                return;
            }

            log("Found sidebar-box, creating resizer...");

            // 如果已经存在，则移除旧的
            const existing = document.getElementById('sidebar-resizer');
            if (existing) {
                log("[SidebarResizer] Removing old resizer");
                existing.remove();
            }

            // 创建新的 resizer 元素
            const resizer = document.createElement('div');
            resizer.id = 'sidebar-resizer';
            resizer.title = 'Drag to resize sidebar';

            // 立即添加到 DOM
            sidebarBox.appendChild(resizer);
            log("✅ Sidebar resizer added to DOM");

            // 绑定事件
            setupResizerEvents(resizer, sidebarBox);

        } catch (e) {
            console.error("Failed to create resizer:", e);
        }
    }

    // 设置拖动事件 - 分离函数便于管理
    function setupResizerEvents(resizer, sidebarBox) {
        let isResizing = false;
        let startX = 0;
        let startWidth = 0;
        let currentWidth = 0;

        log("[SidebarResizer] Setting up resizer events");

        // 默认隐藏调节条
        resizer.style.opacity = '0';
        resizer.style.pointerEvents = 'auto'; // 始终启用鼠标事件

        resizer.addEventListener('mousedown', function (e) {
            if (e.button !== 0) return; // 只响应左键

            log("[SidebarResizer] Mousedown on resizer");
            isResizing = true;
            startX = e.clientX;

            // 获取当前宽度
            const computedStyle = window.getComputedStyle(sidebarBox);
            startWidth = parseInt(computedStyle.width) || 200;
            log("[SidebarResizer] Start resizing from width:", startWidth);

            // 临时禁用过渡动画以便拖动流畅
            sidebarBox.classList.add('dragging');

            // 设置全局样式
            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';

            // 保持调节条可见
            resizer.style.opacity = '1';

            e.preventDefault();
            e.stopPropagation();
        }, true);

        document.addEventListener('mousemove', function (e) {
            if (!isResizing) return;

            const deltaX = e.clientX - startX;
            currentWidth = Math.max(40, Math.min(500, startWidth + deltaX));

            log("[SidebarResizer] Dragging - new width:", currentWidth);

            // 应用新宽度（实时更新）
            sidebarBox.style.setProperty('--uc-sidebar-current-width', currentWidth + 'px');
            sidebarBox.style.width = currentWidth + 'px';

        }, true);

        document.addEventListener('mouseup', function (e) {
            if (!isResizing) return;

            log("[SidebarResizer] Mouseup - final width:", currentWidth);

            isResizing = false;

            // 恢复过渡动画
            sidebarBox.classList.remove('dragging');

            // 恢复全局样式
            document.body.style.cursor = '';
            document.body.style.userSelect = '';

            // 保存宽度
            if (currentWidth > 0) {
                saveSidebarWidth(currentWidth);
            }

            // 隐藏调节条
            resizer.style.opacity = '0';

            e.preventDefault();
            e.stopPropagation();
        }, true);

        // 防止事件冒泡
        resizer.addEventListener('click', function (e) {
            e.stopPropagation();
        });

        // 鼠标悬停显示调节条
        resizer.addEventListener('mouseenter', function () {
            if (!isResizing) {
                log("[SidebarResizer] Mouse enter resizer");
                resizer.style.opacity = '1';
            }
        });

        resizer.addEventListener('mouseleave', function () {
            if (!isResizing) {
                log("[SidebarResizer] Mouse leave resizer");
                resizer.style.opacity = '0';
            }
        });
    }

    // 保存侧边栏宽度
    function saveSidebarWidth(width) {
        try {
            xPref.set('userChrome.sidebar.width', width.toString());
        } catch (e) {
            console.warn("Failed to save sidebar width");
        }
    }

    // 加载保存的宽度
    function loadSavedWidth() {
        try {
            const savedWidth = xPref.get('userChrome.sidebar.width', '');
            if (savedWidth) {
                const width = parseInt(savedWidth);
                if (width >= 40 && width <= 500) {
                    const sidebarBox = document.getElementById('sidebar-box');
                    if (sidebarBox) {
                        setTimeout(() => {
                            sidebarBox.style.setProperty('--uc-sidebar-current-width', width + 'px');
                            sidebarBox.style.width = width + 'px';
                        }, 0);
                    }
                }
            }
        } catch (e) {
            console.warn('Failed to load sidebar width');
        }
    }

    // 自动隐藏功能部分
    function initSidebarAutohide() {
        try {
            log("开始初始化侧边栏自动隐藏功能...");

            // 异步添加CSS和按钮
            setTimeout(() => {
                createToggleButtons();
                applyAutohideState();
            }, 0);

            log("侧边栏自动隐藏初始化完成");

        } catch (e) {
            console.error("侧边栏自动隐藏初始化失败:", e);
        }
    }



    // 创建切换按钮
    function createToggleButtons() {
        let button = document.getElementById("sidebar-autohide-toggle");

        if (button) {
            log("Autohide button already exists, updating attributes");
            button.setAttribute("removable", "true");
            button.setAttribute("class", "toolbarbutton-1 chromeclass-toolbar-additional");
            return;
        }

        // 创建按钮元素
        const buttonContainer = document.createElement("div");
        buttonContainer.id = "sidebar-autohide-toggle";
        buttonContainer.className = "toolbarbutton-1 chromeclass-toolbar-additional";
        buttonContainer.setAttribute("tooltiptext", "切换侧边栏自动隐藏功能");
        buttonContainer.setAttribute("removable", "true");

        // 设置按钮样式
        buttonContainer.style.cssText = `
            width: 32px !important;
            height: 32px !important;
            min-width: 32px !important;
            margin: 0 2px !important;
            border-radius: 4px !important;
            background: transparent !important;
            border: none !important;
            cursor: pointer !important;
            user-select: none !important;
            position: relative !important;
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
        `;

        // 绑定点击事件
        buttonContainer.addEventListener("click", function (event) {
            log("[Autohide] Button clicked");
            event.stopPropagation();
            event.preventDefault();
            toggleSidebarAutohide(event);
        }, {
            capture: true,
            passive: false
        });

        // 异步添加到导航栏
        setTimeout(() => {
            const navbar = document.getElementById("nav-bar");
            if (navbar && !document.getElementById("sidebar-autohide-toggle")) {
                navbar.insertBefore(buttonContainer, navbar.firstChild);
                log("按钮已添加到导航栏最左侧");
            }
        }, 0);
    }

    // 获取保存的状态
    function getAutohideState() {
        try {
            const value = xPref.get("uc.sidebar.autohide");
            return value === true || value === "true";
        } catch (e) {
            return true; // 默认值
        }
    }

    // 保存状态
    function setAutohideState(state) {
        try {
            xPref.set("uc.sidebar.autohide", state);
        } catch (e) {
            // 静默失败或简单记录
            console.warn("Failed to save autohide state");
        }
    }

    // 切换自动隐藏状态
    function toggleSidebarAutohide(event) {
        event.stopPropagation();
        event.preventDefault();

        try {
            const currentStatus = getAutohideState();
            const newStatus = !currentStatus;
            log("[Autohide] Toggling from", currentStatus, "to", newStatus);

            setAutohideState(newStatus);
            applyAutohideState();

            // 强制刷新按钮状态（避免延迟）
            updateAutohideButton();

        } catch (e) {
            console.error("切换侧边栏自动隐藏失败:", e);
        }

        return false;
    }

    // 更新按钮图标和状态
    function updateAutohideButton() {
        const button = document.getElementById("sidebar-autohide-toggle");
        if (!button) {
            log("[Autohide] Button not found for update");
            return;
        }

        try {
            const isEnabled = getAutohideState();
            log("[Autohide] Updating button state:", isEnabled);

            button.style.backgroundImage = 'none';

            if (isEnabled) {
                button.classList.remove("autohide-disabled");
                button.setAttribute("tooltiptext", "侧边栏自动隐藏功能 (当前: 自动隐藏)");
                button.style.setProperty('background-image', `url("${ICONS.autohide}")`, 'important');
            } else {
                button.classList.add("autohide-disabled");
                button.setAttribute("tooltiptext", "侧边栏自动隐藏功能 (当前: 锁定显示)");
                button.style.setProperty('background-image', `url("${ICONS.locked}")`, 'important');
            }

            button.style.backgroundSize = '16px 16px';
            button.style.backgroundRepeat = 'no-repeat';
            button.style.backgroundPosition = 'center';

        } catch (e) {
            console.error("更新按钮状态失败:", e);
        }
    }

    // 应用自动隐藏状态
    function applyAutohideState() {
        const sidebarBox = document.getElementById("sidebar-box");
        if (!sidebarBox) {
            log("[Autohide] Sidebar box not found");
            return;
        }

        try {
            const isEnabled = getAutohideState();
            log("[Autohide] Applying state:", isEnabled);

            if (isEnabled) {
                enableAutohide(sidebarBox);
            } else {
                disableAutohide(sidebarBox);
            }

            updateAutohideButton();

        } catch (e) {
            console.error("应用自动隐藏状态失败:", e);
        }
    }

    // 启用自动隐藏
    function enableAutohide(sidebarBox) {
        log("[Autohide] Enabling autohide");
        sidebarBox.classList.add("autohide-enabled");
        sidebarBox.classList.remove("autohide-disabled");
    }

    // 禁用自动隐藏
    function disableAutohide(sidebarBox) {
        log("[Autohide] Disabling autohide");
        sidebarBox.classList.remove("autohide-enabled");
        sidebarBox.classList.add("autohide-disabled");
    }

    // 启动初始化 - 使用事件监听器确保时机正确
    function startInitialization() {
        if (document.readyState === 'loading') {
            log("Document still loading, waiting for DOMContentLoaded");
            document.addEventListener('DOMContentLoaded', () => {
                initSidebarResizerAndAutohide();
            });
        } else {
            // 使用 setTimeout 确保不会阻塞当前执行
            log("Document loaded, starting initialization");
            setTimeout(() => {
                initSidebarResizerAndAutohide();
            }, 100);
        }
    }

    // 启动初始化过程
    startInitialization();

})();

