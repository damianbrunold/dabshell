import os
import sys
import platform


KEY_LEFT = -1
KEY_RIGHT = -2
KEY_UP = -3
KEY_DOWN = -4
KEY_HOME = -5
KEY_END = -6
KEY_PAGEUP = -7
KEY_PAGEDOWN = -8
KEY_BACKSPACE = -9
KEY_DELETE = -10
KEY_LF = -11
KEY_CR = -12
KEY_TAB = -13
KEY_ESC = -14

KEY_CTRL_A = -101
KEY_CTRL_B = -102
KEY_CTRL_C = -103
KEY_CTRL_D = -104
KEY_CTRL_E = -105
KEY_CTRL_F = -106
KEY_CTRL_G = -107
KEY_CTRL_H = -108
KEY_CTRL_I = -109
KEY_CTRL_J = -110
KEY_CTRL_K = -111
KEY_CTRL_L = -112
KEY_CTRL_M = -113
KEY_CTRL_N = -114
KEY_CTRL_O = -115
KEY_CTRL_P = -116
KEY_CTRL_Q = -117
KEY_CTRL_R = -118
KEY_CTRL_S = -119
KEY_CTRL_T = -120
KEY_CTRL_U = -121
KEY_CTRL_V = -122
KEY_CTRL_W = -123
KEY_CTRL_X = -124
KEY_CTRL_Y = -125
KEY_CTRL_Z = -126


class RawInput:
    def __init__(self):
        self.iswin = platform.system() == "Windows"
        if self.iswin:
            import msvcrt
            self.msvcrt = msvcrt
        else:
            import tty
            import termios
            self.old_settings = termios.tcgetattr(sys.stdin)

    def getch(self):
        if self.iswin:
            ch = self.msvcrt.getwch()
            n = ord(ch)
            if n in [0x0, 0xe0]:
                n = ord(self.msvcrt.getwch())
                if n == 0x4b: return KEY_LEFT
                elif n == 0x4d: return KEY_RIGHT
                elif n == 0x48: return KEY_UP
                elif n == 0x50: return KEY_DOWN
                elif n == 0x53: return KEY_DELETE
                elif n == 0x47: return KEY_HOME
                elif n == 0x4f: return KEY_END
                elif n == 0x51: return KEY_PAGEDOWN
                elif n == 0x49: return KEY_PAGEUP
                else:
                    print(hex(n))
            elif n == 0x8:
                return KEY_BACKSPACE
            elif n == 0x9:
                return KEY_TAB
            elif n == 0xa:
                return KEY_LF
            elif n == 0xd:
                return KEY_CR
            elif n == 0x1b:
                return KEY_ESC
            elif n <= 26:
                return -100 - n  # implicitly map to KEY_CTRL_*
            else:
                return ch
        else:
            # TODO parse codes...
            return sys.stdin.read(1)

    def __enter__(self):
        tty.setraw(sys.stdin)
        return self

    def __exit__(self, type, value, traceback):
        if not self.iswin:
            termios.tcsetattr(
                sys.stdin,
                termios.TCSADRAIN,
                self.old_settings,
            )


def dabshell():
    os.system("")
    inp = RawInput()
    outp = sys.stdout
    line = ""
    index = 0
    log = False
    while True:
        key = inp.getch()
        if key == KEY_CTRL_C:
            break
        elif key == KEY_LF or key == KEY_CR:
            outp.write("\u001b[1000D")
            print("\nechoing... ", line)
            line = ""
            index = 0
        elif key == KEY_ESC:
            line = ""
            index = 0
        elif key == KEY_BACKSPACE:
            if index > 0:
                line = line[:index-1] + line[index:]
                index -= 1
        elif key == KEY_LEFT:
            index = max(0, index-1)
        elif key == KEY_RIGHT:
            index = min(len(line), index+1)
        elif key == KEY_DELETE:
            if index < len(line):
                line = line[:index] + line[index+1:]
        elif key == KEY_HOME:
            index = 0
        elif key == KEY_END:
            index = len(line)
        elif key == KEY_PAGEDOWN:
            index = len(line)
        elif key == KEY_PAGEUP:
            index = 0
        elif type(key) == str:
            line = line[:index] + key + line[index:]
            index += 1

        # Print current input-string
        outp.write("\u001b[1000D")  # Move all the way left
        outp.write(line)
        outp.write(u"\u001b[0K")
        if index < len(line):
            outp.write("\u001b[1000D")  # Move all the way left
            if index > 0:
                outp.write("\u001b[" + str(index) + "C")  # Move cursor to index
        outp.flush()

if __name__ == "__main__":
    dabshell()
