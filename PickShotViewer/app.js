// PickShot Web Viewer - Client Photo Selection
// Loads photos from Google Drive folder, allows selection, saves .pickshot result

(function() {
    'use strict';

    // === State ===
    let photos = [];          // [{id, name, thumbnailUrl, selected}]
    let folderId = '';
    let accessToken = '';
    let folderName = '';
    const STORAGE_KEY = 'pickshot_selections';

    // === Init ===
    window.addEventListener('DOMContentLoaded', init);

    function init() {
        const params = new URLSearchParams(window.location.search);
        folderId = params.get('folder') || '';
        accessToken = params.get('token') || '';
        folderName = params.get('name') || 'PickShot';

        if (!folderId || !accessToken) {
            showError('링크가 올바르지 않습니다. 포토그래퍼에게 다시 요청해주세요.');
            return;
        }

        document.querySelector('.logo').textContent = folderName;
        loadPhotos();
    }

    // === Google Drive API ===
    async function loadPhotos() {
        try {
            const query = `'${folderId}' in parents and mimeType contains 'image/' and trashed=false`;
            const fields = 'files(id,name,thumbnailLink,webContentLink)';
            const orderBy = 'name';
            let allFiles = [];
            let pageToken = '';

            do {
                const url = `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(query)}&fields=nextPageToken,${fields}&orderBy=${orderBy}&pageSize=1000${pageToken ? '&pageToken=' + pageToken : ''}`;
                const res = await fetch(url, {
                    headers: { 'Authorization': `Bearer ${accessToken}` }
                });

                if (!res.ok) {
                    if (res.status === 401) {
                        showError('링크가 만료되었습니다. 포토그래퍼에게 새 링크를 요청해주세요.');
                    } else {
                        showError('사진을 불러올 수 없습니다. (오류: ' + res.status + ')');
                    }
                    return;
                }

                const data = await res.json();
                allFiles = allFiles.concat(data.files || []);
                pageToken = data.nextPageToken || '';

                document.getElementById('loadingProgress').textContent =
                    `${allFiles.length}장 발견...`;
            } while (pageToken);

            if (allFiles.length === 0) {
                showError('폴더에 사진이 없습니다.');
                return;
            }

            // Restore saved selections
            const saved = loadSavedSelections();

            photos = allFiles.map((f, i) => ({
                id: f.id,
                name: f.name,
                thumbnailUrl: f.thumbnailLink ? f.thumbnailLink.replace('=s220', '=s400') : '',
                fullUrl: f.webContentLink || '',
                selected: saved.includes(f.name),
                index: i
            }));

            document.getElementById('totalCount').textContent = photos.length;
            updateSelectCount();

            // Hide loading, show grid
            document.getElementById('loading').style.display = 'none';
            renderGrid();

            // Start multi-threaded preloading
            preloadImages();

        } catch (err) {
            showError('네트워크 오류: ' + err.message);
        }
    }

    // === Render ===
    function renderGrid() {
        const grid = document.getElementById('grid');
        grid.innerHTML = '';

        photos.forEach((photo, i) => {
            const div = document.createElement('div');
            div.className = 'photo' + (photo.selected ? ' selected' : '');
            div.dataset.index = i;
            div.onclick = () => toggleSelect(i);

            // Check mark
            const check = document.createElement('div');
            check.className = 'check';
            check.textContent = '\u2713';

            // Image
            const img = document.createElement('img');
            img.className = 'loading';
            img.alt = photo.name;
            img.loading = 'lazy';

            // Use thumbnail URL
            if (photo.thumbnailUrl) {
                img.src = photo.thumbnailUrl;
                img.onload = () => img.className = 'loaded';
                img.onerror = () => {
                    // Fallback: show skeleton
                    const skel = document.createElement('div');
                    skel.className = 'skeleton';
                    div.insertBefore(skel, check);
                    img.style.display = 'none';
                };
            } else {
                const skel = document.createElement('div');
                skel.className = 'skeleton';
                div.appendChild(skel);
            }

            // Number label
            const num = document.createElement('div');
            num.className = 'num';
            num.textContent = i + 1;

            div.appendChild(img);
            div.appendChild(check);
            div.appendChild(num);
            grid.appendChild(div);
        });
    }

    // === Selection ===
    function toggleSelect(index) {
        photos[index].selected = !photos[index].selected;

        // Update DOM
        const div = document.querySelectorAll('.photo')[index];
        if (div) {
            div.classList.toggle('selected', photos[index].selected);
        }

        updateSelectCount();
        saveSelections();

        // Haptic feedback (if available)
        if (navigator.vibrate) {
            navigator.vibrate(10);
        }
    }

    function updateSelectCount() {
        const count = photos.filter(p => p.selected).length;
        document.getElementById('selectCount').textContent = count;
        document.getElementById('completeBtnCount').textContent = count;

        const btn = document.getElementById('completeBtn');
        btn.disabled = count === 0;
    }

    // === Persistence ===
    function saveSelections() {
        const selected = photos.filter(p => p.selected).map(p => p.name);
        try {
            localStorage.setItem(STORAGE_KEY + '_' + folderId, JSON.stringify(selected));
        } catch (e) { /* ignore */ }
    }

    function loadSavedSelections() {
        try {
            const data = localStorage.getItem(STORAGE_KEY + '_' + folderId);
            return data ? JSON.parse(data) : [];
        } catch (e) { return []; }
    }

    // === Complete Selection ===
    window.completeSelection = function() {
        const count = photos.filter(p => p.selected).length;
        if (count === 0) return;

        document.getElementById('confirmCount').textContent = count;
        document.getElementById('confirmModal').style.display = 'flex';
    };

    window.closeModal = function() {
        document.getElementById('confirmModal').style.display = 'none';
    };

    window.submitSelection = async function() {
        document.getElementById('confirmModal').style.display = 'none';

        const selected = photos.filter(p => p.selected);

        // Build .pickshot JSON
        const pickshot = {
            version: '1.0',
            appVersion: 'PickShot WebViewer',
            exportDate: new Date().toISOString(),
            sourceFolderName: folderName,
            totalPhotos: photos.length,
            selectedPhotos: selected.length,
            files: selected.map(p => ({
                name: p.name.replace(/\.[^.]+$/, ''),  // Remove extension
                rating: 1,
                spacePick: false,
                gSelect: true,
                colorLabel: 'none',
                comments: []
            }))
        };

        const jsonStr = JSON.stringify(pickshot, null, 2);
        const blob = new Blob([jsonStr], { type: 'application/json' });

        try {
            // Upload .pickshot file to the same Google Drive folder
            const metadata = {
                name: `client_selection_${new Date().toISOString().slice(0,10)}.pickshot`,
                parents: [folderId],
                mimeType: 'application/json'
            };

            const form = new FormData();
            form.append('metadata', new Blob([JSON.stringify(metadata)], { type: 'application/json' }));
            form.append('file', blob);

            const res = await fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart', {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${accessToken}` },
                body: form
            });

            if (res.ok) {
                document.getElementById('doneCount').textContent = selected.length;
                document.getElementById('doneModal').style.display = 'flex';

                // Clear saved selections
                localStorage.removeItem(STORAGE_KEY + '_' + folderId);
            } else {
                // Fallback: download file
                downloadPickshot(jsonStr);
            }
        } catch (err) {
            // Fallback: download file
            downloadPickshot(jsonStr);
        }
    };

    function downloadPickshot(jsonStr) {
        const blob = new Blob([jsonStr], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `client_selection.pickshot`;
        a.click();
        URL.revokeObjectURL(url);

        document.getElementById('doneCount').textContent = photos.filter(p => p.selected).length;
        document.getElementById('doneModal').style.display = 'flex';
    }

    // === Multi-threaded Image Preloading ===
    function preloadImages() {
        // Use requestIdleCallback for background preloading
        const batchSize = 6;  // Load 6 images at a time
        let loadIndex = 0;

        function loadBatch() {
            const batch = photos.slice(loadIndex, loadIndex + batchSize);
            if (batch.length === 0) return;

            const promises = batch.map(photo => {
                if (!photo.thumbnailUrl) return Promise.resolve();
                return new Promise(resolve => {
                    const img = new Image();
                    img.onload = resolve;
                    img.onerror = resolve;
                    img.src = photo.thumbnailUrl;
                });
            });

            Promise.all(promises).then(() => {
                loadIndex += batchSize;
                if (loadIndex < photos.length) {
                    if ('requestIdleCallback' in window) {
                        requestIdleCallback(loadBatch);
                    } else {
                        setTimeout(loadBatch, 50);
                    }
                }
            });
        }

        // Start after initial render
        setTimeout(loadBatch, 500);
    }

    // === Error ===
    function showError(msg) {
        document.getElementById('loading').style.display = 'none';
        document.getElementById('error').style.display = 'flex';
        document.getElementById('errorMessage').textContent = msg;
    }

})();
