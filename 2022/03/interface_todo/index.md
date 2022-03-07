# Interface接口的设计


interface在golang是一个非常重要的特性：duck typing，通过interface实现duck typing，使我们无需显式的类型继承

> **duck typing**：是程序设计中动态类型的一种风格。
>
> 在这种风格中，一个对象有效的语义，不是由继承自特定的类或实现特定的接口，而是由"当前方法和属性的集合"决定。
>
> 在鸭子类型中，关注点在于对象的行为，能做什么；而不是关注对象所属的类型。例如，在不使用鸭子类型的语言中，我们可以编写一个函数，它接受一个类型为"鸭子"的对象，并调用它的"走"和"叫"方法。在使用鸭子类型的语言中，这样的一个函数可以接受一个任意类型的对象，并调用它的"走"和"叫"方法。如果这些需要被调用的方法不存在，那么将引发一个运行时错误。任何拥有这样的正确的"走"和"叫"方法的对象都可被函数接受的这种行为引出了以上表述，这种决定类型的方式因此得名。

## 一、数据结构

Go根据接口类型是否包含一组方法将接口类型分成两类：

- 使用`iface`表示方法的接口
- 使用`eface`表示不包含任何方法的`interface{}`类型

### 1、eface

先来介绍简单的`eface`，由于`interface{}`不包含任何方法，所以它的结构比较简单，只包含指向底层数据和类型的两个指针。

```go
type eface struct {
	_type *_type         
	data  unsafe.Pointer 
}
```

而`_type`类型就是Go运行时表示类型

```go
type _type struct {
	size       uintptr
	ptrdata    uintptr
	hash       uint32
	tflag      tflag
	align      uint8
	fieldAlign uint8
	kind       uint8
	equal func(unsafe.Pointer, unsafe.Pointer) bool
	gcdata    *byte
	str       nameOff
	ptrToThis typeOff
}
```

- `size`：存储类型占用的内存空间大小
- `ptrdata`：存储数据的指针地址
- `hash`：快速判断两个类型是否相等
- `equal` 字段用于判断当前类型的多个对象是否相等

### 2、iface

指向有原始数据的指针，更重要的是`itab`字段

```go
type iface struct {
	tab  *itab          
	data unsafe.Pointer 
}
```

每个`itab`都占用32字节，可以看成接口类型和具体类型的组合

```go
type itab struct {
	inter *interfacetype 
	_type *_type         
	hash  uint32         
	_     [4]byte// 填充字符，内存对齐
	fun [1]uintptr 
}
```

- `inter`：接口类型
- `_type`：具体类型
- `hash`是对`_type.hash`的拷贝，当对`interface`进行断言时，可以快速判断类型是否一致
- `fun`：动态大小的数组，用于动态派发的虚函数表，存储了一组函数指针。

## 二、类型转换

### 2.1、指针类型

```go
package main

type Animal interface {
	Run()
}

type Dog struct {
	Name string
}

func (d *Dog) Run() {
	println(d.Name, "is running")
}

func main() {
	var d Animal = &Dog{Name: "wangcai"}
	d.Run()
}
```

用编译器将上述代码编译成汇编语言

```shell
$  go tool compile —N -l -S main.go > main.S
```

```text
LEAQ	type."".Dog(SB), AX
MOVQ	AX, (SP)
CALL	runtime.newobject(SB)
MOVQ	8(SP), AX
MOVQ	$7, 8(AX)
LEAQ	go.string."wangcai"(SB), CX
MOVQ	CX, (AX)

LEAQ	go.itab.*"".Dog,"".Animal(SB), CX
MOVQ	AX, (SP)

CALL	"".(*Dog).Run(SB)
```

**初始化流程**

1、获取`Dog`结构体类型指针并将其作为参数放到栈上

2、通过调用`newobject`函数，这个函数会以`Dog`结构体类型指针作为入参，分配一片新的内存空间并指向这片内存空间的指针返回到SP+8上

3、SP+8存储了一个指向`Dog`结构体的指针，将栈上的指针拷贝到寄存器`AX`

4、由于`Dog`中只包含了一个字符串类型的`Name`变量，所以这里会将字符串地址"wangcai"和字符串长度7设置到结构体上

**类型转换**

5、`Dog`作为一个包含方法的接口，在底层使用`iface`结构体表示，把编译生成的`itab`结构体复制到SP上

6、此时，SP~SP+16共同组成了`iface`结构体，调用`(*Dog).Run`方法。这里动态派发的方法调用改成对目标方法的直接调用，减少性能的额外开销。

### 2.2、结构体类型

这里我们把方法的指针去除

```go
package main

type Animal interface {
	Run()
}

type Dog struct {
	Name string
}

func (d Dog) Run() {
	println(d.Name, "is running")
}

func main() {
	var d Animal = Dog{Name: "wangcai"}
	d.Run()
}
```

同样进行汇编，多出来了` runtime.convT2I`函数

```go
func convT2I(tab *itab, elem unsafe.Pointer) (i iface) {
	t := tab._type
	x := mallocgc(t.size, t, true)
	typedmemmove(t, x, elem)
	i.tab = tab
	i.data = x
	return
}
```

SP 和 SP+8 中存储的 `runtime.itab` 和 `Dog` 指针是 `runtime.convT2I`函数的入参，这个函数的返回值位于 SP+16，是一个占 16 字节内存空间的 `runtime.iface` 结构体，SP+32 存储的是在栈上的 `Dog` 结构体，它会在 `runtime.convT2I` 执行的过程中拷贝到堆上。

## 三、类型断言

### 3.1、空接口

```go
var c interface{} = &Dog{Name: "wangcai"}
s, ok := c.(*Dog)
s = c.(*Dog)
```

就是将`Dog`转成`eface`，调用assertE2I或assertE2I2

### 3.2、非空接口

```go
var c Animal = &Dog{Name: "wangcai"}
switch c.(type) {
case *Dog:
	d := c.(*Dog)
	d.Run()
}
```

同样先是初始化流程，然后进行类型转换，这里就不详细介绍了。

而这里调用assertI2I或assertI2I2

## 四、itab












