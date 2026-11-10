package com.gaurav.touchremote;

import android.content.Context;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

/**
 * An invisible text target that types onto the Mac.
 *
 * A hidden EditText doesn't work for this: keyboards compose words — autocorrect,
 * predictions, swipe typing — and then rewrite them, and forwarding each rewrite
 * as new typing duplicates and garbles text. Backspace on an empty field also
 * never reaches the app. Owning the InputConnection fixes both: when the
 * keyboard replaces its composing word, only the difference is sent, as
 * backspaces plus new characters.
 */
public class RemoteKeyboard extends View {

    public interface Sink {
        void text(String s);
        void key(String name);   // back, enter, tab, esc, left, right, up, down
    }

    private final Sink sink;
    private String composing = "";
    /** Recent text sent to the Mac. Keyboards count deletions in UTF-16 units,
     *  but one Mac Delete removes a whole character (an emoji is 2-11 units),
     *  so this is what converts one into the other. */
    private final StringBuilder recent = new StringBuilder();

    public RemoteKeyboard(Context c, Sink sink) {
        super(c);
        this.sink = sink;
        setFocusable(true);
        setFocusableInTouchMode(true);
    }

    @Override public boolean onCheckIsTextEditor() { return true; }

    @Override public InputConnection onCreateInputConnection(EditorInfo out) {
        // No suggestions + visible-password: most keyboards then commit each
        // character directly instead of holding a composing word.
        out.inputType = InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD;
        out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
                | EditorInfo.IME_FLAG_NO_FULLSCREEN
                | EditorInfo.IME_ACTION_NONE;
        out.initialSelStart = 0;
        out.initialSelEnd = 0;
        composing = "";

        return new BaseInputConnection(this, false) {
            @Override public boolean commitText(CharSequence t, int pos) {
                replaceComposing(t == null ? "" : t.toString());
                composing = "";
                return true;
            }

            @Override public boolean setComposingText(CharSequence t, int pos) {
                String next = t == null ? "" : t.toString();
                replaceComposing(next);
                composing = next;
                return true;
            }

            @Override public boolean finishComposingText() {
                composing = "";
                return true;
            }

            @Override public boolean deleteSurroundingText(int before, int after) {
                composing = "";
                deleteUnits(before);
                return true;
            }

            @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
                composing = "";
                int units = 0, end = recent.length();
                for (int i = 0; i < before && end - units > 0; i++)
                    units += Character.charCount(recent.codePointBefore(end - units));
                int extra = before - recent.codePointCount(end - units, end);
                deleteUnits(units);
                for (int i = 0; i < extra; i++) back();
                return true;
            }

            @Override public boolean sendKeyEvent(KeyEvent e) {
                if (e.getAction() != KeyEvent.ACTION_DOWN) return true;
                switch (e.getKeyCode()) {
                    case KeyEvent.KEYCODE_DEL:          back(); break;
                    case KeyEvent.KEYCODE_ENTER:
                    case KeyEvent.KEYCODE_NUMPAD_ENTER: sink.key("enter"); break;
                    case KeyEvent.KEYCODE_TAB:          sink.key("tab"); break;
                    case KeyEvent.KEYCODE_ESCAPE:       sink.key("esc"); break;
                    case KeyEvent.KEYCODE_DPAD_LEFT:    sink.key("left"); break;
                    case KeyEvent.KEYCODE_DPAD_RIGHT:   sink.key("right"); break;
                    case KeyEvent.KEYCODE_DPAD_UP:      sink.key("up"); break;
                    case KeyEvent.KEYCODE_DPAD_DOWN:    sink.key("down"); break;
                    default:
                        int u = e.getUnicodeChar();
                        if (u > 0) sendText(new String(Character.toChars(u)));
                }
                return true;
            }

            @Override public boolean performEditorAction(int action) {
                sink.key("enter");
                return true;
            }
        };
    }

    /** The keyboard rewrote its in-progress word: send only what changed. */
    private void replaceComposing(String next) {
        // Compare whole characters, never splitting an emoji or a letter+mark.
        java.text.BreakIterator a = java.text.BreakIterator.getCharacterInstance();
        java.text.BreakIterator b = java.text.BreakIterator.getCharacterInstance();
        a.setText(composing); b.setText(next);
        int common = 0, ea = a.next(), eb = b.next();
        while (ea != java.text.BreakIterator.DONE && ea == eb
                && composing.regionMatches(common, next, common, ea - common)) {
            common = ea; ea = a.next(); eb = b.next();
        }
        deleteUnits(composing.length() - common);
        if (common < next.length()) sendText(next.substring(common));
    }

    private void sendText(String t) {
        if (t.isEmpty()) return;
        recent.append(t);
        if (recent.length() > 400) recent.delete(0, recent.length() - 200);
        sink.text(t);
    }

    private void back() {
        if (recent.length() > 0) {
            java.text.BreakIterator it = java.text.BreakIterator.getCharacterInstance();
            it.setText(recent.toString());
            int start = it.preceding(recent.length());
            recent.setLength(Math.max(0, start));
        }
        sink.key("back");
    }

    /** Delete the last n UTF-16 units as the Mac sees them: one Delete per character. */
    private void deleteUnits(int n) {
        if (n <= 0) return;
        int known = Math.min(n, recent.length());
        if (known > 0) {
            String tail = recent.substring(recent.length() - known);
            java.text.BreakIterator it = java.text.BreakIterator.getCharacterInstance();
            it.setText(tail);
            int chars = 0;
            for (int e = it.next(); e != java.text.BreakIterator.DONE; e = it.next()) chars++;
            recent.setLength(recent.length() - known);
            for (int i = 0; i < chars; i++) sink.key("back");
        }
        for (int i = known; i < n; i++) sink.key("back");   // text we never saw: best guess
    }

    public void show() {
        requestFocus();
        InputMethodManager im = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (im != null) {
            im.restartInput(this);
            im.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
        }
    }

    /** Typing to the Mac: the commands its command server already understands. */
    public static Sink toMac() {
        return new Sink() {
            public void text(String s) { Link.get().sendLine("K " + s.replace("\n", "\\n")); }
            public void key(String name) {
                Link.get().sendLine("P " + name);
            }
        };
    }
}
