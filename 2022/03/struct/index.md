# Struct的使用场景


golang里有个重要的类型就是结构体，虽然不能像C++一样有类的功能和特性，但也有自己独特的魅力。

这里着重介绍一下经常遇到的空结构体，我们经常在一些源码中看到`struct{}`这样的定义，在`channel`，`map`中经常出现，那么这到底是为什么？

## 一、空结构体

```go
type emptyStruct struct{}

func main() {
	a := new(emptyStruct)
	b := new(emptyStruct)

	println(a, b, a == b)

	c := new(emptyStruct)
	d := new(emptyStruct)

	fmt.Println(c, d, c == d)
	println(c, d, c == d)
}
```

输出结果为：

```go
0xc00011df47 0xc00011df47 false
&{} &{} true
0xecbde0 0xecbde0 true
```

 可以看到`new`了两个结构体，第一次比较是`false`，第二次比较是`true`。

我们猜测这里可能发生了逃逸，使用命令

```shell
$ go run -gcflags "-m -l" main.go
.\main.go:8:10: new(emptyStruct) does not escape
.\main.go:9:10: new(emptyStruct) does not escape
.\main.go:13:10: new(emptyStruct) escapes to heap
.\main.go:14:10: new(emptyStruct) escapes to heap
.\main.go:16:13: ... argument does not escape
.\main.go:16:22: c == d escapes to heap
```

我们发现确实发生了逃逸现象，未逃逸的变量分配在栈上，逃逸的变量分配在堆上。

在堆上分配的变量通过`mallocgc`函数分配到了`zerobase`这个地址。

## 二、zerobase是什么

`zerobase`是一个`uintptr`的全局变量，占用8个字节。当在任何地方定义零值内存分配时(channel，slice，map)，都是`zerobase`。

```go
func mallocgc(size uintptr, typ *_type, needzero bool) unsafe.Pointer {
	if size == 0 {
		return unsafe.Pointer(&zerobase)
	}
	...
}
```

因为定义的零值使用`zerobase`，所以不占用内存空间。

## 三、定义空结构体的方法

### 1、原生定义

```go
a := struct{}{}
```

### 2、重定义

```go
type emptyStruct struct{}
```

### 3、组合

```go
type emptyStruct struct{}
type object1 struct {
    emptyStruct
}

type object2 struct {
    _ struct{}
}
```

### 4、内置字段

- 空结构体不占用内存
- 地址偏移，用作内存对齐
- 整体类型长度要和最长字段类型长度对齐

---

```go
type object1 struct {
	s struct{}
	b byte
}

type object2 struct {
	s struct{}
	n int64
}

type object3 struct {
	b byte
	s struct{}
	n int64
}

type object4 struct {
	b byte
	s struct{}
}

type object5 struct {
	n int64
	s struct{}
}

func main() {
	println(unsafe.Sizeof(object1{}))
	println(unsafe.Sizeof(object2{}))
	println(unsafe.Sizeof(object3{}))
	println(unsafe.Sizeof(object4{}))
	println(unsafe.Sizeof(object5{}))
}
```

输出：

```go
1
8
16
2
16
```

### 5、指针接受者

```go
type emptyStruct1 struct{}

func (e *emptyStruct1) Func() {
	println(e)
}

type emptyStruct2 struct {}

func (e *emptyStruct2) Func() {
	println(e)
}

func main() {
	s := emptyStruct1{}
	s.Func()
	s2 := emptyStruct2{}
	s2.Func()
}

// Output：
0xc00004df78
0xc00004df78
```

- receiver 作为第一个参数传入函数
- 空结构体作为receiver，实际上不需要传入，因为空结构体没有值
- receiver为一个指针的场景，地址作为第一个参数传入函数，函数调用时，编译器传入`zerobase`




