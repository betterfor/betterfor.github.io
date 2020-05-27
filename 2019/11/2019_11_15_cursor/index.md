# linux光标控制




<img src="https://raw.githubusercontent.com/betterfor/betterfor.github.io/image/images/2019_11_15_cursor.gif">

### Linux下终端 C语言控制光标

```c
// 清除屏幕

#define CLEAR() printf("\033[2J")

// 上移光标

#define MOVEUP(x) printf("\033[%dA", (x))

// 下移光标

#define MOVEDOWN(x) printf("\033[%dB", (x))

// 左移光标

#define MOVELEFT(y) printf("\033[%dD", (y))

// 右移光标

#define MOVERIGHT(y) printf("\033[%dC",(y))

// 定位光标

#define MOVETO(x,y) printf("\033[%d;%dH", (x), (y))

// 光标复位

#define RESET_CURSOR() printf("\033[H")

// 隐藏光标

#define HIDE_CURSOR() printf("\033[?25l")

// 显示光标

#define SHOW_CURSOR() printf("\033[?25h")

//反显

#define HIGHT_LIGHT() printf("\033[7m")

#define UN_HIGHT_LIGHT() printf("\033[27m")
```

那么在golang下是同样的原理

```go
// 上移光标
func moveUp(line int) {
	fmt.Printf("\033[%dA",line)
}

// 下移光标
func moveDown(line int) {
	fmt.Printf("\033[%dB",line)
}
```

这样，我们在打印的时候控制好内容，然后将光标上移到初始位置再重复打印，即可实现动态效果。

```go
package main

import (
	"fmt"
	"github.com/betterfor/goutil/colorString"
	"sync"
	"time"
)

func main() {
	text := "hello"
	for i := 0; i < 3; i++ {
		fmt.Println(text)
	}
	time.Sleep(time.Second)
	moveUp(3)
	text = "hello"
	for i := 0; i < 3; i++ {
		fmt.Println(text + colorString.Sprintf(" [green]ok"))
		time.Sleep(time.Second)
	}
}
```

