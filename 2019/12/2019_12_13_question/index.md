# iota的使用


请看题

```go
const (
	azero = iota
	aone = iota
)

const (
	bmsg = "msg"
	bzero = iota
	bone = iota
)

func main() {
	fmt.Println(azero,aone)
	fmt.Println(bzero,bone)
}
```

这段代码将输出什么？

------

```c
0 1
1 2    
```

##### 知识点：iota的使用

在一个常量声明代码中，如果iota没出现在第一行，则常量的初始值就是非0值