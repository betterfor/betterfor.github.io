---
title: "string和[]byte相互转换"
date: 2022-03-07T11:16:04+08:00
draft: false

tags: ['string','byte','analysis']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

在之前的`slice`中有提到到`[]byte`和`string`之间可以使用`copy`命令转换，那么`string`和`[]byte`还有什么其他方式可以转化？他们到底有什么区别？

## 一、string和[]byte对比

### 1.1、什么是string

根据标准库的`builtin`的解释

```go
type string string 
string is the set of all strings of 8-bit bytes, conventionally but not
necessarily representing UTF-8-encoded text. A string may be empty, but
not nil. Values of string type are immutable.
```

简单来说就是字符串是一系列8位字节的集合，通常但不一定代表UTF-8编码的文本。字符串可以为空，但不能为`nil`。而且字符串是不能修改的。

### 1.2、什么是byte

byte就是uint8的别名

### 1.3、string和[]byte占用内存

```go
import "unsafe"

func main() {
	str := "hello world"
	bytes := []byte("hello world")
	println(unsafe.Sizeof(str))
	println(unsafe.Sizeof(bytes))
}

// Output:
16
24
```

`string`和`[]byte`占用内存是不一样的。

`string`的源码结构为

```go
type stringStruct struct{
    str unsafe.Pointer
    len int
}
```

`[]byte`的实现其实就是切片的实现。

根据结构，我们可以得到，`string`占用16字节，`[]byte`占用24字节

## 二、字符串不能修改

准确的说是字符串的值不能被修改，但整体能够被替换。

```go
str := "hello world"
str[0] = 'w'
```

这种运行会报错。

这是因为`string`的指针指向的内容不能更改，每更改一次内存，都需要重新分配内存。

这同样也是直接操作`string`比`[]byte`低效的原因。

## 三、string和[]byte互相转换

### 1、`string` to `[]byte`

```go
func stringtoslicebyte(buf *tmpBuf, s string) []byte {
	var b []byte
	if buf != nil && len(s) <= len(buf) {
		*buf = tmpBuf{}
		b = buf[:len(s)]
	} else {
		b = rawbyteslice(len(s))
	}
	copy(b, s)
	return b
}
```

```go
func rawbyteslice(size int) (b []byte) {
	cap := roundupsize(uintptr(size))
	p := mallocgc(cap, nil, false)
	if cap != uintptr(size) {
		memclrNoHeapPointers(add(p, uintptr(size)), cap-uintptr(size))
	}

	*(*slice)(unsafe.Pointer(&b)) = slice{p, size, int(cap)}
	return
}
```

这里其实就是先分配`[]byte`的长度，然后拷贝s到b。

`copy`调用的还是`slicestringcopy`函数，将`[]byte`的0号位置指向string的数组指针

```go
func slicestringcopy(to []byte, fm string) int {
	if len(fm) == 0 || len(to) == 0 {
		return 0
	}

	n := len(fm)
	if len(to) < n {
		n = len(to)
	}

	memmove(unsafe.Pointer(&to[0]), stringStructOf(&fm).str, uintptr(n))
	return n
}
```

### 2、`[]byte` to `string`

```go
func slicebytetostring(buf *tmpBuf, b []byte) (str string) {
	l := len(b)
	if l == 0 {
		return ""
	}
	if l == 1 {
		stringStructOf(&str).str = unsafe.Pointer(&staticbytes[b[0]])
		stringStructOf(&str).len = 1
		return
	}

	var p unsafe.Pointer
	if buf != nil && len(b) <= len(buf) {
		p = unsafe.Pointer(buf)
	} else {
		p = mallocgc(uintptr(len(b)), nil, false)
	}
	stringStructOf(&str).str = p
	stringStructOf(&str).len = len(b)
	memmove(p, (*(*slice)(unsafe.Pointer(&b))).array, uintptr(len(b)))
	return
}
```

可以看到str的地址也是重新分配内存的。

所以`string`和`[]byte`相互转换都会有新的内存分配，是消耗性能的。

对应的方式就是`string(b)`和`[]byte(s)`。

## 四、特殊的转换方式

我们其实已经知道底层是指向同一块内存空间的，那么我们可以用如下的方式：

```go
func stringtoslicebyte(s string) []byte {
	sh := (*reflect.StringHeader)(unsafe.Pointer(&s))
	bh := reflect.SliceHeader{
		Data: sh.Data,
		Len:  sh.Len,
		Cap: sh.Len,
	}
	return *(*[]byte)(unsafe.Pointer(&bh))
}

func slicebytetostring(b []byte) string {
	bh := (*reflect.SliceHeader)(unsafe.Pointer(&b))
	sh := reflect.StringHeader{
		Data: bh.Data,
		Len:  bh.Len,
	}
	return *(*string)(unsafe.Pointer(&sh))
}

func main() {
	var str string = "hello world"
	b1 := stringtoslicebyte(str)
	println(b1)

	str1 := slicebytetostring(b1)
	println(str1)
}
```

但是用的`unsafe`包，直接基于结构体进行转换，一旦造成`panic`，是无法`recover`的。

## 五、总结

- `string`可以比较，`[]byte`不能比较，所以map的key不能是`[]byte`
- 因为无法修改`string`的某个字符，所以需要转成`[]byte`，然后才能修改
- `string`不能为nil
- `[]byte`是切片类型
- 大量的字符串处理，使用`[]byte`，性能会更优