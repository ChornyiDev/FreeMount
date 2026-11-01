# Google OAuth Verification Demo Video Script — FreeMount

This document contains a step-by-step recording guide and an exact narration script for the Google OAuth Verification demo video.

- **App Name:** FreeMount
- **Client ID:** `319728381325-v71u1mjithqc6ovqvbb4mnc0hhbf0r65.apps.googleusercontent.com`
- **Scope requested:** `https://www.googleapis.com/auth/drive`
- **Video length:** ~1 to 2 minutes
- **YouTube settings:** Set to **Unlisted** (Google reviewers can view via direct link).

---

## Video Recording Checklist (What Google strictly checks)
1. **Show the Client ID clearly in the browser address bar** during the OAuth consent flow (`client_id=319728381325-v71u1mjithqc6ovqvbb4mnc0hhbf0r65...`).
2. **Show the OAuth consent screen** with the FreeMount logo and application name.
3. If the "Google hasn't verified this app" warning appears, click **Advanced** -> **Go to FreeMount (unsafe)** (Google explicitly expects to see this in demo videos for unverified apps).
4. **Demonstrate how the scope is used in the app:**
   - Mount Google Drive.
   - Show Google Drive files appearing natively in macOS Finder.
   - Open a file or create a small test file to demonstrate read and write capability.

---

## English Narration Script (Voiceover / Speaking Text)

### Scene 1: Introduction (0:00 - 0:15)
> "Hello. In this video, I will demonstrate how FreeMount uses the Google Drive API scope: `https://www.googleapis.com/auth/drive`.
> FreeMount is an open-source native macOS application that integrates remote cloud storage directly into macOS Finder using Apple's File Provider framework."

### Scene 2: Initiating Sign-In & Demonstrating Client ID (0:15 - 0:40)
*(Action: In FreeMount, click Add Connection -> Select Google Drive -> Click Connect / Sign in. The browser opens the Google OAuth consent page.)*

> "Now, I am adding a new Google Drive connection in FreeMount and initiating the sign-in flow.
> Notice the browser URL: here is our assigned Client ID: `319728381325-v71u1mjithqc6ovqvbb4mnc0hhbf0r65.apps.googleusercontent.com`.
> On the consent screen, the FreeMount brand logo and app details are shown.
> I will now grant permission to allow FreeMount to manage Google Drive files."

*(Action: Click Continue / Grant access. If the 'unverified' warning shows, click Advanced -> Go to FreeMount -> Allow).*

### Scene 3: Showing File Listing in macOS Finder (0:40 - 1:05)
*(Action: The browser redirects back or completes. FreeMount shows the connection as Active / Mounted. Switch to Finder and show the Google Drive folder under Locations / CloudStorage).*

> "The authentication is complete. As you can see, FreeMount mounts the user's Google Drive natively into macOS Finder Locations.
> We need the full Google Drive scope because FreeMount is a full filesystem client. It enumerates the user's existing files and folders directly in Finder so the user can browse their files seamlessly."

### Scene 4: Reading and Writing Files (1:05 - 1:35)
*(Action: Double-click an existing file to show it downloading and opening. Then create a new file, e.g., a text file or duplicate an existing file inside Finder).*

> "When the user opens a file, FreeMount downloads it on-demand.
> And when the user creates a new file, renames, or modifies an existing file locally in Finder, FreeMount uploads those changes back to Google Drive in real time.
> A more restrictive scope, such as `drive.file` or `drive.readonly`, is not sufficient because users need to access and edit their pre-existing files directly through Finder."

### Scene 5: Privacy and Conclusion (1:35 - 1:50)
*(Action: Show FreeMount Settings or the main menu bar popover).*

> "All OAuth credentials and tokens remain strictly stored on the user's local machine in the secure macOS Keychain. No data is sent to any intermediate servers.
> Thank you for reviewing FreeMount."

---

## Український переклад / підказка для вас під час запису

- **Сцена 1 (Початок):** Представте FreeMount як опенсорс утиліту для macOS, що монтує хмарні диски у Finder.
- **Сцена 2 (Авторизація):** Тиснете «Підключити Google Drive». Покажіть курсором на адресний рядок браузера, де написано `client_id=319728381325...`. Тиснете «Увійти» та надаєте доступ.
- **Сцена 3 (Finder):** Покажіть, що у Finder у лівій колонці з'явився диск Google Drive і там видно файли з вашого диску. Поясніть, що скоуп потрібен для відображення існуючих файлів.
- **Сцена 4 (Читання / Запис):** Відкрийте будь-який файл (читання) і створіть тестовий текстовий документ або папку (запис). Поясніть, що тому потрібен повний доступ, а не лише `readonly`.
- **Сцена 5 (Завершення):** Скажіть, що всі токени зберігаються локально в Keychain на комп'ютері користувача без посередників.

