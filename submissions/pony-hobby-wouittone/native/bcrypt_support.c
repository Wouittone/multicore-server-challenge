#include <errno.h>

/* Reentrant error-output helper required by Openwall's crypt_blowfish. */
int _crypt_output_magic(const char *setting, char *output, int size)
{
    if (size < 3) {
        errno = ERANGE;
        return -1;
    }
    output[0] = '*';
    output[1] = (setting[0] == '*' && setting[1] == '0') ? '1' : '0';
    output[2] = '\0';
    return 0;
}
