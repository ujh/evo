/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 * This is Evo, a simple go program.                             *
 *                                                               *
 * Copyright 2023 by Urban Hafner                                *
 *           2003 and 2004 by Gunnar Farnebäck.                  *
 *                                                               *
 * Permission is hereby granted, free of charge, to any person   *
 * obtaining a copy of this file gtp.c, to deal in the Software  *
 * without restriction, including without limitation the rights  *
 * to use, copy, modify, merge, publish, distribute, and/or      *
 * sell copies of the Software, and to permit persons to whom    *
 * the Software is furnished to do so, provided that the above   *
 * copyright notice(s) and this permission notice appear in all  *
 * copies of the Software and that both the above copyright      *
 * notice(s) and this permission notice appear in supporting     *
 * documentation.                                                *
 *                                                               *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY     *
 * KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE    *
 * WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR       *
 * PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN NO      *
 * EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS  *
 * NOTICE BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR    *
 * CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER RESULTING    *
 * FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF    *
 * CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT    *
 * OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS       *
 * SOFTWARE.                                                     *
 *                                                               *
 * Except as contained in this notice, the name of a copyright   *
 * holder shall not be used in advertising or otherwise to       *
 * promote the sale, use or other dealings in this Software      *
 * without prior written authorization of the copyright holder.  *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#include "genann.h"

int boot(int argc, char **argv);
extern genann *ann;
extern double *ann_inputs;
