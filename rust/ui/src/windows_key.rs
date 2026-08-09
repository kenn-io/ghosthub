//! Active Windows keyboard-layout resolution for terminal key identity.

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyboardLayout, HKL, MAPVK_VK_TO_VSC, MapVirtualKeyExW, ToUnicodeEx, VK_SHIFT, VkKeyScanExW,
};

use super::LayoutKey;

const SHIFT_STATE: u8 = 1;
const TRANSLATE_WITHOUT_STATE_CHANGE: u32 = 1 << 2;

pub(super) fn resolve(character: char) -> Option<LayoutKey> {
    let utf16 = u16::try_from(u32::from(character)).ok()?;
    // SAFETY: GetKeyboardLayout has no preconditions for the current thread.
    let layout = unsafe { GetKeyboardLayout(0) };
    // SAFETY: The UTF-16 code unit and layout handle are plain values obtained
    // from Windows for the current UI thread.
    let mapping = unsafe { VkKeyScanExW(utf16, layout) };
    if mapping == -1 {
        return None;
    }
    let mapping = mapping.cast_unsigned();
    let virtual_key = mapping & 0xff;
    let shift_state = (mapping >> 8) as u8;
    // Character faces are optional: AltGr text comes from GPUI's key_char, but
    // the virtual key must survive even if either face cannot be synthesized.
    let unshifted = translate(virtual_key, false, layout);
    let shifted = translate(virtual_key, true, layout);
    Some(LayoutKey {
        virtual_key,
        unshifted,
        shifted,
        shift_required: shift_state & SHIFT_STATE != 0,
    })
}

fn translate(virtual_key: u16, shift: bool, layout: HKL) -> Option<char> {
    let mut state = [0_u8; 256];
    if shift {
        state[usize::from(VK_SHIFT)] = 0x80;
    }
    // SAFETY: layout is the current thread's keyboard layout and the call only
    // reads plain values.
    let scan_code = unsafe { MapVirtualKeyExW(u32::from(virtual_key), MAPVK_VK_TO_VSC, layout) };
    let mut buffer = [0_u16; 8];
    // SAFETY: All pointers refer to live, correctly-sized arrays. The flag asks
    // Windows not to mutate the keyboard layout's dead-key state.
    let length = unsafe {
        ToUnicodeEx(
            u32::from(virtual_key),
            scan_code,
            state.as_ptr(),
            buffer.as_mut_ptr(),
            i32::try_from(buffer.len()).expect("keyboard buffer length fits i32"),
            TRANSLATE_WITHOUT_STATE_CHANGE,
            layout,
        )
    };
    let text = decode_translation(&buffer, length)?;
    let character = super::single_character(&text)?;
    (!character.is_control()).then_some(character)
}

fn decode_translation(buffer: &[u16], length: i32) -> Option<String> {
    if length == 0 {
        return None;
    }
    let length = usize::try_from(length.unsigned_abs()).ok()?;
    String::from_utf16(buffer.get(..length)?).ok()
}

#[cfg(test)]
mod tests {
    use super::decode_translation;

    #[test]
    fn dead_key_translation_preserves_the_returned_character() {
        let buffer = ['^' as u16, 0];

        assert_eq!(decode_translation(&buffer, -1).as_deref(), Some("^"));
        assert_eq!(decode_translation(&buffer, 1).as_deref(), Some("^"));
        assert_eq!(decode_translation(&buffer, 0), None);
    }
}
